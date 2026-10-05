package com.blacicada.h3;

import com.blacicada.common.h3.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.ScheduledFuture;
import java.net.URI;
import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;
import org.apache.logging.log4j.LogManager;

final class LocalRequestHandler extends ChannelInboundHandlerAdapter {
    private final ProxyConfig config;
    private final Http3Session session;
    private final DnsAddressResolverGroup resolver;
    private final DirectRoutes routes;
    private final ArrayDeque<HttpContent> pending = new ArrayDeque<>();
    private int pendingBytes;
    private HttpRequest request;
    private Channel remote;
    private io.netty.util.concurrent.Future<?> opening;
    private boolean tunnel;
    private boolean ready;
    private boolean failed;
    private ScheduledFuture<?> timeout;

    LocalRequestHandler(ProxyConfig config, Http3Session session, DnsAddressResolverGroup resolver, DirectRoutes routes) {
        this.config = config; this.session = session; this.resolver = resolver; this.routes = routes;
    }
    @Override public void channelActive(ChannelHandlerContext ctx) {
        timeout = ctx.executor().schedule(() -> fail(ctx, HttpResponseStatus.GATEWAY_TIMEOUT),
                config.connectTimeoutMillis() * 2L, TimeUnit.MILLISECONDS);
        ctx.fireChannelActive();
    }
    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (failed) { ReferenceCountUtil.release(msg); return; }
        if (msg instanceof HttpRequest incoming && request == null) {
            if (!incoming.decoderResult().isSuccess()) { ReferenceCountUtil.release(msg); fail(ctx, HttpResponseStatus.BAD_REQUEST); return; }
            request = incoming;
            tunnel = HttpMethod.CONNECT.equals(request.method());
            final Authority target;
            try { target = target(request, tunnel); }
            catch (RuntimeException e) { fail(ctx, HttpResponseStatus.BAD_REQUEST); return; }
            ctx.channel().config().setAutoRead(false);
            if (!tunnel) {
                ctx.pipeline().get(HttpRequestDecoder.class).setSingleDecode(false);
                request.headers().set(HttpHeaderNames.HOST, target.toString());
                request.headers().remove("proxy-authorization");
                request.headers().remove("proxy-connection");
                request.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.CLOSE);
                if (HttpUtil.is100ContinueExpected(request)) {
                    ctx.writeAndFlush(new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.CONTINUE));
                    request.headers().remove(HttpHeaderNames.EXPECT);
                }
            }
            if (routes.matches(target.host())) {
                var connecting = new Bootstrap().group(ctx.channel().eventLoop()).channel(NioSocketChannel.class)
                        .resolver(resolver).option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                        .option(ChannelOption.AUTO_READ, false).option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                        .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                        .handler(new ChannelInboundHandlerAdapter()).connect(target.unresolved());
                remote = connecting.channel();
                connecting.addListener((ChannelFutureListener) f -> connected(ctx, f.isSuccess() ? f.channel() : null, f.cause()));
            } else {
                opening = session.open(target);
                opening.addListener(f -> connected(ctx, f.isSuccess() ? (Channel) f.getNow() : null, f.cause()));
            }
        } else if (msg instanceof HttpContent content && request != null) {
            if (!content.decoderResult().isSuccess()) { content.release(); fail(ctx, HttpResponseStatus.BAD_REQUEST); return; }
            if (tunnel) { content.release(); return; }
            pendingBytes += content.content().readableBytes();
            if (pendingBytes > Transport.MAX_PENDING_BYTES) { content.release(); fail(ctx, HttpResponseStatus.REQUEST_ENTITY_TOO_LARGE); }
            else pending.add(content);
        } else { ReferenceCountUtil.release(msg); fail(ctx, HttpResponseStatus.BAD_REQUEST); }
    }

    static Authority target(HttpRequest request, boolean tunnel) {
        if (tunnel) return Authority.parse(request.uri(), -1);
        URI uri = URI.create(request.uri());
        if (uri.getRawFragment() != null || uri.getRawUserInfo() != null) throw new IllegalArgumentException("Invalid request target");
        Authority target;
        if (uri.isAbsolute()) {
            if (!"http".equalsIgnoreCase(uri.getScheme())) throw new IllegalArgumentException("Use CONNECT for HTTPS");
            target = Authority.parse(uri.getRawAuthority(), 80);
            String path = uri.getRawPath();
            request.setUri((path == null || path.isEmpty() ? "/" : path)
                    + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery()));
        } else {
            if (!request.uri().startsWith("/") && !request.uri().equals("*")) throw new IllegalArgumentException("Invalid request target");
            if (request.headers().getAll(HttpHeaderNames.HOST).size() != 1) throw new IllegalArgumentException("Expected one Host header");
            target = Authority.parse(request.headers().get(HttpHeaderNames.HOST), 80);
        }
        return target;
    }

    private void connected(ChannelHandlerContext ctx, Channel channel, Throwable error) {
        if (channel == null) {
            if (error != null) LogManager.getLogger(LocalRequestHandler.class).warn("Proxy connect failed: {}", error.toString());
            fail(ctx, HttpResponseStatus.BAD_GATEWAY); return;
        }
        remote = channel;
        if (failed || !ctx.channel().isActive()) { remote.close(); return; }
        ready = true;
        timeout.cancel(false);
        remote.config().setAutoRead(false);
        remote.pipeline().addLast("relay", new RelayHandler(ctx.channel()));
        if (tunnel) {
            ctx.writeAndFlush(new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK))
                    .addListener(f -> {
                        if (!f.isSuccess() || !ctx.channel().isActive()) { remote.close(); return; }
                        ctx.pipeline().replace(this, "relay", new RelayHandler(remote));
                        ctx.pipeline().remove("responseEncoder");
                        // Removing ByteToMessageDecoder forwards any coalesced tunnel bytes exactly once.
                        ctx.pipeline().remove("requestDecoder");
                        remote.read(); ctx.channel().read();
                    });
        } else {
            ctx.pipeline().remove("responseEncoder");
            remote.pipeline().addLast("httpEncoder", new HttpRequestEncoder());
            remote.writeAndFlush(request).addListener(f -> { if (!f.isSuccess()) { remote.close(); ctx.close(); } });
            request = null;
            var body = new HttpBodyRelay(remote);
            ctx.pipeline().replace(this, "body", body);
            var bodyContext = ctx.pipeline().context(body);
            while (!pending.isEmpty()) body.channelRead(bodyContext, pending.remove());
            // singleDecode may have left an entire coalesced body in the decoder.
            // Resume that cumulation even if the sender has no further socket bytes.
            ctx.pipeline().fireChannelRead(io.netty.buffer.Unpooled.EMPTY_BUFFER);
            remote.read();
            if (body.canRead()) ctx.channel().read();
        }
    }

    private void fail(ChannelHandlerContext ctx, HttpResponseStatus status) {
        if (failed) return;
        failed = true;
        if (opening != null && !opening.isDone()) opening.cancel(false);
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (remote != null) remote.close();
        if (!ctx.channel().isActive()) return;
        var response = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status);
        response.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, 0).set(HttpHeaderNames.CONNECTION, HttpHeaderValues.CLOSE);
        ctx.writeAndFlush(response).addListener(ChannelFutureListener.CLOSE);
    }
    private void releasePending() { while (!pending.isEmpty()) pending.remove().release(); }
    @Override public void handlerRemoved(ChannelHandlerContext ctx) {
        if (timeout != null) timeout.cancel(false);
        if (!ready) releasePending();
    }
    @Override public void channelInactive(ChannelHandlerContext ctx) {
        failed = true;
        if (opening != null && !opening.isDone()) opening.cancel(false);
        if (timeout != null) timeout.cancel(false);
        releasePending();
        if (remote != null) remote.close();
        ctx.fireChannelInactive();
    }
    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { fail(ctx, HttpResponseStatus.BAD_REQUEST); }

    /** Ordinary HTTP uses one request per local connection, with a streaming body. */
    private static final class HttpBodyRelay extends RelayHandler {
        private boolean complete;
        HttpBodyRelay(Channel peer) { super(peer); }
        @Override protected boolean canRead() { return !complete; }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (!(msg instanceof HttpContent content) || complete || !content.decoderResult().isSuccess()) {
                ReferenceCountUtil.release(msg); peer.close(); ctx.close(); return;
            }
            if (msg instanceof LastHttpContent) complete = true;
            super.channelRead(ctx, msg);
        }
    }
}
