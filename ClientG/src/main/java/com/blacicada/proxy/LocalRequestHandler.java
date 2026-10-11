package com.blacicada.proxy;

import com.blacicada.config.DirectRoutes;

import com.blacicada.common.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.ScheduledFuture;
import java.net.URI;
import java.net.InetSocketAddress;
import java.util.ArrayDeque;
import java.util.concurrent.TimeUnit;
import org.apache.logging.log4j.LogManager;

final class LocalRequestHandler extends ChannelInboundHandlerAdapter {
    private final ProxyConfig config;
    private final SessionRouter session;
    private final DnsAddressResolverGroup resolver;
    private final java.util.function.Supplier<DirectRoutes> routeSource;
    private final TrafficStatistics traffic;
    private final java.util.function.Consumer<java.util.Map<String, Object>> accessRecorder;
    private com.blacicada.config.KernelConfig requestConfig;
    private String requestMethod;
    private boolean accessCompleted;
    private final ArrayDeque<HttpContent> pending = new ArrayDeque<>();
    private int pendingBytes;
    private HttpRequest request;
    private Channel remote;
    private LocalSession localSession;
    private io.netty.util.concurrent.Future<?> opening;
    private boolean tunnel;
    private boolean ready;
    private boolean failed;
    private ScheduledFuture<?> timeout;

    LocalRequestHandler(ProxyConfig config, SessionRouter session, DnsAddressResolverGroup resolver, java.util.function.Supplier<DirectRoutes> routes, TrafficStatistics traffic,
                        java.util.function.Consumer<java.util.Map<String, Object>> accessRecorder) {
        this.config = config; this.session = session; this.resolver = resolver; this.routeSource = routes;
        this.traffic = traffic;
        this.accessRecorder = accessRecorder;
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
            route(ctx, target);
        } else if (msg instanceof HttpContent content && request != null) {
            if (!content.decoderResult().isSuccess()) { content.release(); fail(ctx, HttpResponseStatus.BAD_REQUEST); return; }
            if (tunnel) { content.release(); return; }
            pendingBytes += content.content().readableBytes();
            if (pendingBytes > Transport.MAX_PENDING_BYTES) { content.release(); fail(ctx, HttpResponseStatus.REQUEST_ENTITY_TOO_LARGE); }
            else pending.add(content);
        } else { ReferenceCountUtil.release(msg); fail(ctx, HttpResponseStatus.BAD_REQUEST); }
    }

    private void route(ChannelHandlerContext ctx, Authority target) {
        requestConfig = session.config(); requestMethod = request.method().name();
        localSession = new LocalSession(ctx.channel(), target, resolver.getResolver(ctx.executor()), address -> {
            if (failed || !ctx.channel().isActive()) return;
            if (address == null) connectProxy(ctx, target);
            else connectDirect(ctx, address);
        });
        recordAccess("pending");
        ctx.channel().closeFuture().addListener(ignored -> recordAccess("cancelled"));
        localSession.apply(routeSource.get());
    }

    /** 只记录请求目标和连接结果，不记录 URL 路径、查询参数、请求头及正文。 */
    private void recordAccess(String state) {
        if (accessRecorder == null || localSession == null || accessCompleted) return;
        var value = new java.util.LinkedHashMap<String, Object>(localSession.snapshot(requestConfig));
        value.put("requestId", traffic.sessionId() + "/" + value.get("id"));
        value.put("sessionId", traffic.sessionId()); value.put("method", requestMethod);
        value.put("state", state); value.put("completedAt", state.equals("pending") ? 0L : System.currentTimeMillis());
        accessCompleted = !state.equals("pending");
        accessRecorder.accept(java.util.Map.copyOf(value));
    }

    private void connectDirect(ChannelHandlerContext ctx, InetSocketAddress address) {
        var connecting = new Bootstrap().group(ctx.channel().eventLoop()).channel(NioSocketChannel.class)
                .resolver(resolver).option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                .option(ChannelOption.AUTO_READ, false).option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                .handler(new ChannelInboundHandlerAdapter()).connect(address);
        remote = connecting.channel();
        localSession.remote(remote);
        connecting.addListener((ChannelFutureListener) f -> connected(ctx, f.isSuccess() ? f.channel() : null, f.cause()));
    }

    private void connectProxy(ChannelHandlerContext ctx, Authority target) {
        opening = session.open(target, ctx.channel());
        opening.addListener(f -> connected(ctx, f.isSuccess() ? (Channel) f.getNow() : null, f.cause()));
    }

    static Authority target(HttpRequest request, boolean tunnel) {
        if (tunnel) return Authority.parse(request.uri(), -1);
        URI uri = URI.create(request.uri());
        if (uri.getRawFragment() != null || uri.getRawUserInfo() != null) throw new IllegalArgumentException("请求目标无效");
        Authority target;
        if (uri.isAbsolute()) {
            if (!"http".equalsIgnoreCase(uri.getScheme())) throw new IllegalArgumentException("HTTPS 请求必须使用 CONNECT");
            target = Authority.parse(uri.getRawAuthority(), 80);
            String path = uri.getRawPath();
            request.setUri((path == null || path.isEmpty() ? "/" : path)
                    + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery()));
        } else {
            if (!request.uri().startsWith("/") && !request.uri().equals("*")) throw new IllegalArgumentException("请求目标无效");
            if (request.headers().getAll(HttpHeaderNames.HOST).size() != 1) throw new IllegalArgumentException("必须且只能提供一个 Host 请求头");
            target = Authority.parse(request.headers().get(HttpHeaderNames.HOST), 80);
        }
        return target;
    }

    private void connected(ChannelHandlerContext ctx, Channel channel, Throwable error) {
        if (failed || !ctx.channel().isActive() || localSession.isClosed()) {
            if (channel != null) Transport.abort(channel);
            return;
        }
        if (channel == null) {
            if (error != null) LogManager.getLogger(LocalRequestHandler.class).warn("代理连接失败：{}", error.toString());
            fail(ctx, HttpResponseStatus.BAD_GATEWAY); return;
        }
        remote = channel;
        if (!localSession.remote(remote)) return;
        recordAccess("connected");
        ready = true;
        timeout.cancel(false);
        remote.config().setAutoRead(false);
        remote.pipeline().addLast("traffic", traffic.handler());
        remote.pipeline().addLast("relay", new RelayHandler(ctx.channel()));
        if (tunnel) {
            ctx.writeAndFlush(new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK))
                    .addListener(f -> {
                        if (!f.isSuccess() || !ctx.channel().isActive()) { remote.close(); return; }
                        ctx.pipeline().replace(this, "relay", new RelayHandler(remote));
                        ctx.pipeline().remove("responseEncoder");
                        // 移除 ByteToMessageDecoder 时，合并接收的隧道数据只转发一次。
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
            // singleDecode 可能将合并接收的完整请求体留在解码器中。
            // 即使发送方不再发送数据，也要继续处理这些累积字节。
            ctx.pipeline().fireChannelRead(io.netty.buffer.Unpooled.EMPTY_BUFFER);
            remote.read();
            if (body.canRead()) ctx.channel().read();
        }
    }

    private void fail(ChannelHandlerContext ctx, HttpResponseStatus status) {
        if (failed) return;
        recordAccess("failed");
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

    /** 普通 HTTP 每条本地连接处理一个请求，请求体按流转发。 */
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
