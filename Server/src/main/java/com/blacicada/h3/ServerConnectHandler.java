package com.blacicada.h3;

import com.blacicada.common.*;
import com.blacicada.common.h3.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http3.*;
import io.netty.handler.codec.quic.QuicStreamChannel;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.ScheduledFuture;
import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;

final class ServerConnectHandler extends ChannelInboundHandlerAdapter {
    private static final org.apache.logging.log4j.Logger LOGGER =
            org.apache.logging.log4j.LogManager.getLogger(ServerConnectHandler.class);
    private Authority requestedTarget;
    private final ProxyConfig config;
    private final ProxyCredentials credentials;
    private final DnsAddressResolverGroup resolver;
    private final ArrayDeque<ByteBuf> pending = new ArrayDeque<>();
    private int pendingBytes;
    private boolean receivedHeaders;
    private boolean finished;
    private Channel target;
    private ScheduledFuture<?> timeout;

    ServerConnectHandler(ProxyConfig config, ProxyCredentials credentials, DnsAddressResolverGroup resolver) {
        this.config = config; this.credentials = credentials; this.resolver = resolver;
    }

    @Override public void handlerAdded(ChannelHandlerContext ctx) {
        timeout = ctx.executor().schedule(() -> fail(ctx, "504"), config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
    }

    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (finished) { ReferenceCountUtil.release(msg); return; }
        if (msg instanceof Http3HeadersFrame frame && !receivedHeaders) {
            receivedHeaders = true;
            if (credentials.authenticate(frame.headers().get("proxy-authorization")) == null) {
                fail(ctx, "407"); return;
            }
            if (!"CONNECT".contentEquals(frame.headers().method()) || frame.headers().scheme() != null
                    || frame.headers().path() != null) { fail(ctx, "400"); return; }
            final Authority authority;
            try { authority = Authority.parse(frame.headers().authority().toString(), -1); }
            catch (RuntimeException e) { fail(ctx, "400"); return; }
            requestedTarget = authority;
            ctx.channel().config().setAutoRead(false);
            var connecting = new Bootstrap().group(ctx.channel().eventLoop()).channel(NioSocketChannel.class)
                    .resolver(resolver).option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                    .option(ChannelOption.AUTO_READ, false).option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                    .handler(new RelayHandler(ctx.channel())).connect(authority.unresolved());
            target = connecting.channel();
            connecting.addListener((ChannelFutureListener) f -> {
                if (finished || !ctx.channel().isActive()) { f.channel().close(); return; }
                if (!f.isSuccess()) { fail(ctx, "502"); return; }
                var response = new DefaultHttp3HeadersFrame(); response.headers().status("200");
                ctx.writeAndFlush(response).addListener(write -> {
                    if (!write.isSuccess() || !ctx.channel().isActive()) { fail(ctx, "502"); return; }
                    finished = true;
                    timeout.cancel(false);
                    ctx.pipeline().addAfter(ctx.name(), "data", new H3DataCodec());
                    ctx.pipeline().addAfter("data", "relay", new RelayHandler(target));
                    while (!pending.isEmpty()) target.write(pending.remove());
                    target.flush();
                    ctx.pipeline().remove(this);
                    target.read();
                    ctx.channel().read();
                });
            });
        } else if (msg instanceof Http3DataFrame frame && receivedHeaders) {
            pendingBytes += frame.content().readableBytes();
            if (pendingBytes > Transport.MAX_PENDING_BYTES) { frame.release(); fail(ctx, "413"); }
            else { pending.add(frame.content().retain()); frame.release(); }
        } else if (msg instanceof Http3UnknownFrame) {
            ReferenceCountUtil.release(msg);
        } else { ReferenceCountUtil.release(msg); fail(ctx, "400"); }
    }

    private void fail(ChannelHandlerContext ctx, String status) {
        if (finished) return;
        finished = true;
        QuicStreamChannel stream = (QuicStreamChannel) ctx.channel();
        LOGGER.warn("CONNECT 请求失败：状态={}，目标={}，连接 ID={}，流 ID={}",
                status, requestedTarget, stream.parent().id().asShortText(), stream.streamId());
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (target != null) target.close();
        var response = new DefaultHttp3HeadersFrame(); response.headers().status(status);
        if (status.equals("407")) response.headers().set("proxy-authenticate", credentials.challenge());
        ctx.writeAndFlush(response).addListener(QuicStreamChannel.SHUTDOWN_OUTPUT);
        // 避免未认证的对端无限期占用半关闭的流。
        ctx.executor().schedule(() -> ctx.close(), 1, TimeUnit.SECONDS);
    }

    private void releasePending() { while (!pending.isEmpty()) pending.remove().release(); }
    @Override public void channelInactive(ChannelHandlerContext ctx) {
        finished = true;
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (target != null) target.close();
        ctx.fireChannelInactive();
    }
    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        if (target != null) target.close();
        ctx.close();
    }
}
