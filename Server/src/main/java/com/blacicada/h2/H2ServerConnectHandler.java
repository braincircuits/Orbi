package com.blacicada.h2;

import com.blacicada.common.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http2.*;
import com.blacicada.common.h2.H2DataCodec;

import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.ScheduledFuture;

import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;

final class H2ServerConnectHandler extends ChannelInboundHandlerAdapter {
    private static final org.apache.logging.log4j.Logger LOGGER =
            org.apache.logging.log4j.LogManager.getLogger(H2ServerConnectHandler.class);
    private Authority requestedTarget;
    private final ProxyConfig config;
    private final ProxyCredentials credentials;
    private final DnsAddressResolverGroup resolver;
    private final io.netty.resolver.dns.DnsServerAddressStreamProvider dnsServers;
    private DnsTunnel dns;
    private final ArrayDeque<ByteBuf> pending = new ArrayDeque<>();
    private int pendingBytes;
    private boolean receivedHeaders;
    private boolean finished;
    private Channel target;
    private ScheduledFuture<?> timeout;
    private String phase = "等待 CONNECT 请求头";

    H2ServerConnectHandler(ProxyConfig config, ProxyCredentials credentials, DnsAddressResolverGroup resolver,
                           io.netty.resolver.dns.DnsServerAddressStreamProvider dnsServers) {
        this.config = config;
        this.credentials = credentials;
        this.resolver = resolver;
        this.dnsServers = dnsServers;
    }

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) {
        timeout = ctx.executor().schedule(() -> fail(ctx, "504", new java.io.IOException(
                        "CONNECT 处理超时：阶段=" + phase + "，超时预算=" + config.connectTimeoutMillis() + "ms")),
                config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (finished) {
            ReferenceCountUtil.release(msg);
            return;
        }
        if (msg instanceof Http2HeadersFrame frame && !receivedHeaders) {
            if (frame.isEndStream()) {
                fail(ctx, "400", new IllegalArgumentException("CONNECT 请求头不能携带 END_STREAM"));
                return;
            }
            receivedHeaders = true;
            if (credentials.authenticate(frame.headers().get("proxy-authorization")) == null) {
                fail(ctx, "407");
                return;
            }
            if (!"CONNECT".contentEquals(frame.headers().method()) || frame.headers().scheme() != null
                    || frame.headers().path() != null) {
                fail(ctx, "400", new IllegalArgumentException("请求必须为 CONNECT，且不能包含 scheme 或 path"));
                return;
            }
            final Authority authority;
            final boolean udp;
            try {
                authority = Authority.parse(frame.headers().authority().toString(), -1);
                udp = UdpTunnel.requested(frame.headers().getAll(UdpTunnel.HEADER));
                dns = DnsTunnel.requested(frame.headers().getAll(DnsTunnel.HEADER), authority);
            } catch (RuntimeException e) {
                fail(ctx, "400", e);
                return;
            }
            requestedTarget = authority;
            ctx.channel().config().setAutoRead(false);
            final java.net.InetSocketAddress destination;
            try {
                destination = dns == null ? authority.unresolved() : dns.upstream(dnsServers);
            } catch (RuntimeException e) {
                fail(ctx, "502", e);
                return;
            }
            phase = udp ? "建立 UDP 目标通道（含地址解析）" : "建立 TCP 目标连接（含地址解析）";
            if (udp) {
                var opening = UdpTunnel.connect(ctx.channel().eventLoop(), resolver, destination);
                ctx.channel().closeFuture().addListener(ignored -> opening.cancel(false));
                opening.addListener(f -> connected(ctx, f.isSuccess() ? (Channel) f.getNow() : null, f.cause(), true));
                return;
            }
            var connecting = new Bootstrap().group(ctx.channel().eventLoop()).channel(NioSocketChannel.class)
                    .resolver(resolver).option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                    .option(ChannelOption.AUTO_READ, false).option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                    .handler(new ChannelInboundHandlerAdapter()).connect(destination);
            target = connecting.channel();
            connecting.addListener((ChannelFutureListener) f -> connected(ctx, f.isSuccess() ? f.channel() : null, f.cause(), false));
        } else if (msg instanceof Http2DataFrame frame && receivedHeaders) {
            pendingBytes += frame.content().readableBytes();
            if (pendingBytes > Transport.MAX_PENDING_BYTES) {
                frame.release();
                fail(ctx, "413");
            } else if (frame.isEndStream()) {
                frame.release();
                fail(ctx, "400");
            } else {
                pending.add(frame.content().retain());
                frame.release();
            }
        } else if (msg instanceof Http2WindowUpdateFrame) {
            ReferenceCountUtil.release(msg);
        } else {
            ReferenceCountUtil.release(msg);
            fail(ctx, "400");
        }
    }

    private void connected(ChannelHandlerContext ctx, Channel connected, Throwable failure, boolean udp) {
        if (connected != null) target = connected;
        if (finished || !ctx.channel().isActive()) {
            if (connected != null) connected.close();
            return;
        }
        if (failure != null) {
            fail(ctx, "502", failure);
            return;
        }
        var response = new DefaultHttp2HeadersFrame(new DefaultHttp2Headers());
        response.headers().status("200");
        if (udp) response.headers().set(UdpTunnel.HEADER, UdpTunnel.VALUE);
        if (dns != null) response.headers().set(DnsTunnel.HEADER, dns.header());
        phase = "发送 CONNECT 成功响应";
        ctx.writeAndFlush(response).addListener(write -> {
            if (finished) {
                target.close();
                ctx.close();
                return;
            }
            if (!write.isSuccess() || !ctx.channel().isActive()) {
                fail(ctx, "502", write.cause());
                return;
            }
            finished = true;
            timeout.cancel(false);
            ctx.pipeline().addAfter(ctx.name(), "data", new H2DataCodec());
            if (udp) UdpTunnel.addFraming(ctx.pipeline());
            ctx.pipeline().addLast("relay", udp ? UdpTunnel.relay(target) : new RelayHandler(target));
            target.pipeline().addLast("relay", udp ? UdpTunnel.relay(ctx.channel()) : new RelayHandler(ctx.channel()));
            // 排队的 DATA 已拆去 HTTP 帧，从字节流解码入口继续处理，保留 UDP 边界。
            var data = ctx.pipeline().context("data");
            ctx.pipeline().remove(this);
            while (!pending.isEmpty()) data.fireChannelRead(pending.remove());
            data.fireChannelReadComplete();
            target.read();
            ctx.channel().read();
        });
    }

    private void fail(ChannelHandlerContext ctx, String status) {
        fail(ctx, status, null);
    }

    private void fail(ChannelHandlerContext ctx, String status, Throwable cause) {
        if (finished) return;
        finished = true;
        Http2StreamChannel stream = (Http2StreamChannel) ctx.channel();
        LOGGER.warn("CONNECT 请求失败：状态={}，目标={}，连接 ID={}，流 ID={}，DNS={}，阶段={}，原因={}",
                status, requestedTarget, stream.parent().id().asShortText(), stream.stream().id(), dns,
                phase, cause == null ? "无底层异常" : cause.getClass().getSimpleName());
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (target != null) target.close();
        var response = new DefaultHttp2HeadersFrame(new DefaultHttp2Headers());
        response.headers().status(status);
        if (status.equals("407")) response.headers().set("proxy-authenticate", credentials.challenge());
        ctx.writeAndFlush(new DefaultHttp2HeadersFrame(response.headers(), true));
        // 避免未认证的对端无限期占用半关闭的流。
        ctx.executor().schedule(() -> ctx.close(), 1, TimeUnit.SECONDS);
    }

    private void releasePending() {
        while (!pending.isEmpty()) pending.remove().release();
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) {
        finished = true;
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (target != null) target.close();
        ctx.fireChannelInactive();
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
        if (event instanceof Http2ResetFrame) ctx.close();
        else ctx.fireUserEventTriggered(event);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        if (target != null) target.close();
        ctx.close();
    }
}
