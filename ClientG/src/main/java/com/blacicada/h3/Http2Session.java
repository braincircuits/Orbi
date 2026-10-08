package com.blacicada.h3;

import com.blacicada.common.h3.*;
import com.blacicada.common.h2.H2DataCodec;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.handler.timeout.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.*;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** 会话分配、排队和关闭只在所属事件循环中执行。 */
public final class Http2Session implements ProxySession {
    private final EventLoop loop;
    private final ProxyConfig config;
    private final DnsAddressResolverGroup resolver;
    private final Authority server;
    private final String authorization;
    private final SslContext ssl;
    private final DefaultChannelGroup parents;
    private final AtomicLong count = new AtomicLong();
    private final Set<Request> requests = new LinkedHashSet<>();
    private Channel connection;
    private Promise<Channel> connecting;
    private boolean closed;
    private volatile String state = "idle", error = "", stage = "idle";
    private static final org.apache.logging.log4j.Logger LOG = org.apache.logging.log4j.LogManager.getLogger(Http2Session.class);

    private static final class Capacity {
        long maximum;
        int active;
        boolean creating, draining;
    }
    private static final io.netty.util.AttributeKey<Capacity> CAPACITY = io.netty.util.AttributeKey.valueOf("h2.capacity");
    private final class Request {
        final Authority target;
        final Promise<Channel> result = loop.newPromise();
        Channel parent;
        Http2StreamChannel stream;
        boolean starting;
        String phase = "等待 HTTP/2 流额度";
        long waitingSince, phaseSince;
        ScheduledFuture<?> timeout;
        Request(Authority target) { this.target = target; }
    }
    public Http2Session(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver) throws Exception {
        this.loop = loop; this.config = config; this.resolver = resolver;
        parents = new DefaultChannelGroup(loop);
        server = new Authority(config.required("server.host"), config.integer("server.port", 4433, 1, 65535));
        authorization = ProxyCredentials.clientAuthorization(config);
        var builder = SslContextBuilder.forClient().sslProvider(SslProvider.JDK)
                    .ciphers(Http2SecurityUtil.CIPHERS, SupportedCipherSuiteFilter.INSTANCE)
                .applicationProtocolConfig(new ApplicationProtocolConfig(ApplicationProtocolConfig.Protocol.ALPN,
                        ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                        ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2"));
        if (!config.get("tls.ca", "").isEmpty()) builder.trustManager(config.path("tls.ca", "").toFile());
        ssl = builder.build();
    }
    @Override public Future<Channel> open(Authority target) {
        Request r = new Request(target);
        loop.execute(() -> {
            if (r.result.isDone()) return;
            if (closed || requests.size() >= config.maxStreams()) {
                r.result.tryFailure(new IOException("代理不可用或已达到并发流上限")); return;
            }
            requests.add(r);
            r.result.addListener(f -> {
                if (r.timeout != null) r.timeout.cancel(false);
                if (!f.isSuccess()) {
                    requests.remove(r);
                    if (r.stream != null) r.stream.close();
                    if (!f.isCancelled()) error = "HTTP/2 隧道建立失败：" + f.cause().getClass().getSimpleName();
                }
            });
            acquire().addListener(f -> {
                if (r.result.isDone()) return;
                if (!f.isSuccess()) { r.result.tryFailure(f.cause()); return; }
                r.parent = (Channel) f.getNow();
                r.waitingSince = r.phaseSince = System.nanoTime();
                r.timeout = loop.schedule(() -> r.result.tryFailure(timeoutError(r)),
                        config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
                drain(r.parent);
            });
        });
        return r.result;
    }
    /** 在清理请求之前采集快照，额度占用包含已预留但尚未完成创建的流。 */
    private IOException timeoutError(Request r) {
        Capacity capacity = r.parent.attr(CAPACITY).get();
        long queued = requests.stream().filter(item -> item.parent == r.parent && !item.starting && !item.result.isDone()).count();
        long now = System.nanoTime();
        String streamId = r.stream == null || r.stream.stream().id() < 0 ? "未分配" : Integer.toString(r.stream.stream().id());
        return new IOException(r.phase + "超时：目标=" + r.target
                + "，连接 ID=" + r.parent.id().asShortText() + "，流 ID=" + streamId
                + "，本地地址=" + r.parent.localAddress() + "，服务端地址=" + r.parent.remoteAddress()
                + "，对端并发上限=" + (capacity == null ? "未知" : capacity.maximum)
                + "，本连接占用=" + (capacity == null ? "未知" : capacity.active) + "，排队=" + queued
                + "，当前阶段耗时=" + TimeUnit.NANOSECONDS.toMillis(now - r.phaseSince) + "ms"
                + "，总等待=" + TimeUnit.NANOSECONDS.toMillis(now - r.waitingSince) + "ms"
                + "，超时预算=" + config.connectTimeoutMillis() + "ms");
    }
    private void phase(Request r, String phase) { r.phase = phase; r.phaseSince = System.nanoTime(); }
    private void drain(Channel parent) {
        Capacity c = parent.attr(CAPACITY).get();
        if (c == null || c.creating) return;
        for (Request r : new ArrayList<>(requests)) {
            if (r.parent != parent || r.starting || r.result.isDone()) continue;
            if (!parent.isActive() || c.draining) { r.result.tryFailure(new IOException("HTTP/2 连接不再接收新流")); continue; }
            if (c.active >= c.maximum) return;
            r.starting = true; c.creating = true; c.active++;
            phase(r, "创建 HTTP/2 流");
            new Http2StreamChannelBootstrap(parent).handler(new Response(r))
                    .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK).open().addListener(f -> {
                        c.creating = false;
                        if (!f.isSuccess()) { c.active--; r.result.tryFailure(f.cause()); }
                        else {
                            r.stream = (Http2StreamChannel) f.getNow();
                            r.stream.closeFuture().addListener(ignored -> {
                                c.active--; requests.remove(r);
                                if (c.draining && c.active == 0) parent.close();
                                else drain(parent);
                            });
                            if (r.result.isDone()) r.stream.close();
                            else {
                                phase(r, "发送 HTTP/2 CONNECT");
                                r.stream.writeAndFlush(new DefaultHttp2HeadersFrame(new DefaultHttp2Headers()
                                    .method("CONNECT").authority(r.target.toString()).set("proxy-authorization", authorization)))
                                    .addListener(w -> {
                                        if (!w.isSuccess()) r.result.tryFailure(w.cause());
                                        else if (!r.result.isDone()) phase(r, "等待 HTTP/2 CONNECT 响应");
                                    });
                            }
                        }
                        loop.execute(() -> drain(parent));
                    });
            return;
        }
    }
    private Future<Channel> acquire() {
        if (closed) return loop.newFailedFuture(new IOException("代理会话已关闭"));
        if (connection != null && connection.isActive()) return loop.newSucceededFuture(connection);
        if (connecting != null) return connecting;
        Promise<Channel> attempt = loop.newPromise(); connecting = attempt; state = "connecting"; error = ""; stage = "dns";
        var timer = loop.schedule(() -> attempt.tryFailure(new IOException("HTTP/2 连接超时：阶段=" + stage)), config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        var tcp = new Bootstrap().group(loop).channel(NioSocketChannel.class).resolver(resolver)
                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                .handler(new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        parents.add(ch);
                        Capacity capacity = new Capacity(); ch.attr(CAPACITY).set(capacity);
                        var tls = ssl.newHandler(ch.alloc(), config.get("tls.serverName", server.host()), server.port());
                        var parameters = tls.engine().getSSLParameters(); parameters.setEndpointIdentificationAlgorithm("HTTPS");
                        tls.engine().setSSLParameters(parameters); tls.setHandshakeTimeoutMillis(config.connectTimeoutMillis());
                        ch.pipeline().addLast(tls);
                        ch.pipeline().addLast(new ApplicationProtocolNegotiationHandler("") {
                            @Override protected void configurePipeline(ChannelHandlerContext ctx, String protocol) throws Exception {
                                stage = "http2_settings";
                                if (!protocol.equals("h2")) throw new IOException("代理服务端未协商 HTTP/2");
                                ctx.pipeline().addLast(new IdleStateHandler(0, 0, config.idleTimeoutSeconds(), TimeUnit.SECONDS));
                                ctx.pipeline().addLast(Http2FrameCodecBuilder.forClient().initialSettings(new Http2Settings()
                                        .pushEnabled(false).maxHeaderListSize(Transport.MAX_HEADER_SIZE).initialWindowSize(256 * 1024)).build());
                                ctx.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
                                        if (msg instanceof Http2SettingsFrame settings) {
                                            Long limit = settings.settings().maxConcurrentStreams();
                                            capacity.maximum = limit == null ? (attempt.isDone() ? capacity.maximum : Long.MAX_VALUE) : limit;
                                            if (!attempt.isDone() && !closed) {
                                                connection = ch; state = "connected"; stage = "connect"; count.incrementAndGet();
                                                LOG.info("与代理服务端的 HTTP/2 连接成功：地址={}，连接 ID={}", server, ch.id().asShortText());
                                                attempt.trySuccess(ch);
                                            }
                                            drain(ch);
                                        } else if (msg instanceof Http2GoAwayFrame) {
                                            capacity.draining = true;
                                            if (connection == ch) { connection = null; state = "idle"; }
                                            drain(ch);
                                            if (capacity.active == 0) ch.close();
                                        }
                                        ctx.fireChannelRead(msg);
                                    }
                                    @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
                                        if (event instanceof IdleStateEvent) ctx.close(); else ctx.fireUserEventTriggered(event);
                                    }
                                    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
                                        attempt.tryFailure(cause); ctx.close();
                                    }
                                });
                                ctx.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Http2StreamChannel>() {
                                    @Override protected void initChannel(Http2StreamChannel stream) { stream.close(); }
                                }));
                            }
                            @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { attempt.tryFailure(cause); ctx.close(); }
                        });
                        ch.closeFuture().addListener(f -> {
                            attempt.tryFailure(new IOException("HTTP/2 连接已关闭"));
                            if (connection == ch) { connection = null; state = "idle"; }
                            for (Request r : new ArrayList<>(requests)) if (r.parent == ch) r.result.tryFailure(new IOException("HTTP/2 连接已断开"));
                            if (attempt.isSuccess()) LOG.info("与代理服务端的 HTTP/2 连接已断开：地址={}，连接 ID={}", server, ch.id().asShortText());
                        });
                    }
                }).register();
        tcp.addListener(registered -> {
            if (!registered.isSuccess()) { attempt.tryFailure(registered.cause()); return; }
            if (attempt.isDone()) return;
            resolver.getResolver(loop).resolve(server.unresolved()).addListener(resolved -> {
                if (attempt.isDone()) return;
                if (!resolved.isSuccess()) { attempt.tryFailure(resolved.cause()); return; }
                stage = "tcp";
                tcp.channel().connect((java.net.SocketAddress) resolved.getNow()).addListener(connected -> {
                    if (!connected.isSuccess()) attempt.tryFailure(connected.cause());
                    else if (!attempt.isDone()) stage = "tls";
                });
            });
        });
        attempt.addListener(f -> {
            timer.cancel(false); if (connecting == attempt) connecting = null;
            if (!f.isSuccess()) { tcp.channel().close(); if (!closed) { state = "failed"; error = "HTTP/2 连接失败：" + f.cause().getClass().getSimpleName(); } }
        });
        return attempt;
    }
    private final class Response extends ChannelInboundHandlerAdapter {
        private final Request request;
        Response(Request request) { this.request = request; }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof Http2HeadersFrame headers) {
                String status = String.valueOf(headers.headers().status());
                if (status.startsWith("1") && !headers.isEndStream()) return;
                if (status.matches("2[0-9]{2}") && !headers.isEndStream()) {
                    ctx.channel().config().setAutoRead(false);
                    ctx.pipeline().replace(this, "data", new H2DataCodec());
                    if (!request.result.trySuccess(ctx.channel())) ctx.close();
                } else request.result.tryFailure(new IOException("代理 CONNECT 失败：" + status));
            } else { ReferenceCountUtil.release(msg); request.result.tryFailure(new IOException("HTTP/2 CONNECT 响应无效")); }
        }
        @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
            if (event instanceof Http2ResetFrame) { request.result.tryFailure(new IOException("HTTP/2 流已重置")); ctx.close(); }
            else ctx.fireUserEventTriggered(event);
        }
        @Override public void channelInactive(ChannelHandlerContext ctx) { request.result.tryFailure(new IOException("CONNECT 流已关闭")); ctx.fireChannelInactive(); }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { request.result.tryFailure(cause); ctx.close(); }
    }
    public String stage() { return stage; }
    public String connectionState() { return state; }
    public String lastError() { return error; }
    public long connectionCount() { return count.get(); }
    @Override public void close() {
        Runnable stop = () -> {
            closed = true;
            if (connecting != null) connecting.tryFailure(new IOException("代理会话已关闭"));
            for (Request r : new ArrayList<>(requests)) r.result.tryFailure(new IOException("代理会话已关闭"));
            parents.close(); state = "idle";
        };
        if (loop.inEventLoop()) stop.run(); else loop.submit(stop).syncUninterruptibly();
    }
}
