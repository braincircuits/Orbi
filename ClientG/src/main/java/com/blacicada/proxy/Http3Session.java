package com.blacicada.proxy;

import com.blacicada.common.*;
import com.blacicada.common.h3.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.handler.codec.http3.*;
import io.netty.handler.codec.quic.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.*;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** 连接与流的分配状态均限制在同一个事件循环内。 */
public final class Http3Session implements ProxySession {
    private static final Logger LOGGER = LogManager.getLogger(Http3Session.class);
    private final EventLoop loop;
    private final ProxyConfig config;
    private final Authority server;
    private final String authorization;
    private final DnsAddressResolverGroup resolver;
    private final Channel udp;
    private final AtomicLong connectionCount = new AtomicLong();
    private QuicChannel connection;
    private Promise<QuicChannel> connecting;
    private boolean closed;
    private int streams;
    private final ArrayDeque<StreamRequest> waitingStreams = new ArrayDeque<>();
    private boolean creatingStream;
    private volatile String connectionState = "idle";
    private volatile String lastError = "";
    private volatile String stage = "idle";
    public String stage() { return stage; }

    public String connectionState() { return connectionState; }
    public String lastError() { return lastError; }

    private record StreamRequest(QuicChannel parent, ChannelHandler handler,
                                 Promise<QuicStreamChannel> promise) { }

    public Http3Session(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver) throws Exception {
        this(loop, config, resolver, OutboundNetwork.DEFAULT);
    }
    public Http3Session(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver, OutboundNetwork network) throws Exception {
        this.loop = loop; this.config = config; this.resolver = resolver;
        authorization = ProxyCredentials.clientAuthorization(config);
        server = new Authority(config.required("server.host"), config.integer("server.port", 4433, 1, 65535));
        Quic.ensureAvailability();
        var sslBuilder = QuicSslContextBuilder.forClient().earlyData(false)
                .applicationProtocols(Http3.supportedApplicationProtocols()).endpointIdentificationAlgorithm("HTTPS");
        if (!config.get("tls.ca", "").isEmpty()) sslBuilder.trustManager(config.path("tls.ca", "").toFile());
        var ssl = sslBuilder.build();
        String serverName = config.get("tls.serverName", server.host());
        var codec = Transport.limits(Http3.newQuicClientCodecBuilder(), config)
                .sslEngineProvider(ch -> ssl.newEngine(ch.alloc(), serverName, server.port()))
                .sslTaskExecutor(ForkJoinPool.commonPool()).build();
        udp = new Bootstrap().group(loop).channelFactory(network::udp).handler(codec)
                .bind(0).sync().channel();
    }

    @Override public Future<QuicStreamChannel> open(Authority target, boolean udpTunnel, DnsTunnel dns) {
        Promise<QuicStreamChannel> result = loop.newPromise();
        loop.execute(() -> {
            if (result.isDone()) return;
            if (closed) {
                result.tryFailure(new IOException("代理会话已关闭")); return;
            }
            if (streams >= config.maxStreams()) {
                result.tryFailure(new IOException("HTTP/3 本地并发隧道额度已满：目标=" + target
                        + "，原始协议=" + (udpTunnel ? "UDP" : "TCP") + "，占用=" + streams
                        + "，上限=" + config.maxStreams() + "，等待流额度=" + waitingStreams.size())); return;
            }
            streams++;
            acquire().addListener(f -> {
                if (result.isDone()) { streams--; return; }
                if (!f.isSuccess()) { streams--; result.tryFailure(f.cause()); return; }
                QuicChannel parent = (QuicChannel) f.getNow();
                var response = new ConnectResponse(result, target, udpTunnel, dns);
                Future<QuicStreamChannel> creation = createWhenAllowed(parent, response);
                result.addListener(done -> { if (!done.isSuccess()) creation.cancel(false); });
                creation.addListener(created -> {
                    if (!created.isSuccess()) { streams--; result.tryFailure(created.cause()); return; }
                    QuicStreamChannel stream = (QuicStreamChannel) created.getNow();
                    stream.closeFuture().addListener(ignored -> streams--);
                    result.addListener(done -> { if (!done.isSuccess()) Transport.abort(stream); });
                    var request = new DefaultHttp3HeadersFrame();
                    request.headers().method("CONNECT").authority(target.toString())
                            .set("proxy-authorization", authorization);
                    if (udpTunnel) request.headers().set(UdpTunnel.HEADER, UdpTunnel.VALUE);
                    if (dns != null) request.headers().set(DnsTunnel.HEADER, dns.header());
                    stream.writeAndFlush(request).addListener(write -> {
                        if (!write.isSuccess()) result.tryFailure(write.cause());
                    });
                });
            });
        });
        return result;
    }

    private Future<QuicStreamChannel> createWhenAllowed(QuicChannel parent, ConnectResponse handler) {
        Promise<QuicStreamChannel> promise = loop.newPromise();
        var request = new StreamRequest(parent, handler, promise);
        handler.observeConnection(parent);
        waitingStreams.add(request);
        var timeout = loop.schedule(() -> {
            var failure = new IOException("等待 QUIC 流额度超时：连接 ID=" + parent.id().asShortText()
                    + "，目标=" + handler.target + "，原始协议=" + (handler.udpTunnel ? "UDP" : "TCP")
                    + "，对端剩余额度=" + parent.peerAllowedStreams(QuicStreamType.BIDIRECTIONAL)
                    + "，本地占用（含排队）=" + streams + "，排队=" + waitingStreams.size()
                    + "，超时预算=" + config.connectTimeoutMillis() + "ms");
            checkUnresponsiveConnection(parent, handler.receivedBefore, handler.sentBefore, "等待 QUIC 流额度");
            promise.tryFailure(failure);
        }, config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        promise.addListener(done -> {
            timeout.cancel(false);
            waitingStreams.remove(request);
        });
        drainWaitingStreams();
        return promise;
    }

    private void drainWaitingStreams() {
        // 本地流关闭后，对端的 MAX_STREAMS 更新可能尚未到达，必须等待真实额度。
        if (creatingStream) return;
        while (!waitingStreams.isEmpty()) {
            StreamRequest request = waitingStreams.peek();
            if (request.promise().isDone()) { waitingStreams.remove(); continue; }
            if (closed || !request.parent().isActive()) {
                waitingStreams.remove();
                request.promise().tryFailure(new IOException("等待流额度期间 HTTP/3 连接已关闭"));
                continue;
            }
            if (request.parent().peerAllowedStreams(QuicStreamType.BIDIRECTIONAL) <= 0) return;
            waitingStreams.remove();
            creatingStream = true;
            Http3.newRequestStreamBootstrap(request.parent(), request.handler())
                    .option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                    .create().addListener(created -> {
                        creatingStream = false;
                        if (created.isSuccess()) {
                            QuicStreamChannel stream = (QuicStreamChannel) created.getNow();
                            if (!request.promise().trySuccess(stream)) Transport.abort(stream);
                        } else request.promise().tryFailure(created.cause());
                        // 下一轮调度避免同步完成回调造成递归，并重新读取剩余额度。
                        loop.execute(this::drainWaitingStreams);
                    });
            return;
        }
    }

    private void failWaitingStreams(QuicChannel parent) {
        for (StreamRequest request : new ArrayList<>(waitingStreams)) {
            if (request.parent() == parent)
                request.promise().tryFailure(new IOException("等待流额度期间 HTTP/3 连接已断开"));
        }
    }

    @Override public Future<Double> latency() {
        Promise<Double> result = loop.newPromise();
        loop.execute(() -> acquire().addListener(ready -> {
            if (result.isDone()) return;
            if (!ready.isSuccess()) { result.tryFailure(ready.cause()); return; }
            QuicChannel channel = (QuicChannel) ready.getNow();
            channel.collectPathStats(0).addListener(measured -> {
                if (!measured.isSuccess()) { result.tryFailure(measured.cause()); return; }
                long nanos = ((QuicConnectionPathStats) measured.getNow()).rtt();
                if (nanos <= 0) result.tryFailure(new IOException("当前 QUIC 连接尚无有效 RTT 样本"));
                else result.trySuccess(nanos / 1_000_000.0);
            });
        }));
        return result;
    }
    private Future<QuicChannel> acquire() {
        if (closed) return loop.newFailedFuture(new IOException("代理会话已关闭"));
        if (connection != null && connection.isActive()) return loop.newSucceededFuture(connection);
        if (connecting != null) return connecting;
        Promise<QuicChannel> attempt = loop.newPromise();
        connecting = attempt;
        connectionState = "connecting";
        stage = "dns";
        lastError = "";
        var deadline = loop.schedule(() -> attempt.tryFailure(new IOException("HTTP/3 握手超时")),
                config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        attempt.addListener(f -> {
            deadline.cancel(false);
            if (connecting == attempt) connecting = null;
            if (!f.isSuccess() && !closed) {
                connectionState = "failed";
                lastError = "服务端连接失败，请检查地址、网络及证书：" + f.cause().getClass().getSimpleName();
            }
        });
        resolver.getResolver(loop).resolve(server.unresolved()).addListener(resolved -> {
            if (attempt.isDone()) return;
            if (!resolved.isSuccess()) { attempt.tryFailure(resolved.cause()); return; }
            stage = "quic_tls";
            var settings = new DefaultHttp3SettingsFrame();
            settings.put(Http3SettingsFrame.HTTP3_SETTINGS_MAX_FIELD_SECTION_SIZE, (long) Transport.MAX_HEADER_SIZE);
            QuicChannel.newBootstrap(udp)
                    .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                    .handler(new ChannelInitializer<QuicChannel>() {
                        @Override protected void initChannel(QuicChannel channel) {
                            channel.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
                                    if (event instanceof QuicStreamLimitChangedEvent) drainWaitingStreams();
                                    ctx.fireUserEventTriggered(event);
                                }
                                @Override public void channelInactive(ChannelHandlerContext ctx) {
                                    failWaitingStreams(channel);
                                    ctx.fireChannelInactive();
                                }
                            });
                            channel.pipeline().addLast(new Http3ClientConnectionHandler(null, null, null, settings, true));
                        }
                    })
                    .remoteAddress((InetSocketAddress) resolved.getNow()).connect().addListener(connected -> {
                        if (!connected.isSuccess()) { attempt.tryFailure(connected.cause()); return; }
                        QuicChannel channel = (QuicChannel) connected.getNow();
                        if (closed || attempt.isDone()) { channel.close(); return; }
                        connection = channel;
                        connectionState = "connected";
                        stage = "connect";
                        lastError = "";
                        connectionCount.incrementAndGet();
                        LOGGER.info("与服务端的 HTTP/3 连接成功：服务端={}，连接 ID={}", server, channel.id().asShortText());
                        channel.closeFuture().addListener(ignored -> {
                            LOGGER.info("与服务端的 HTTP/3 连接已断开：服务端={}，连接 ID={}", server, channel.id().asShortText());
                            if (connection == channel) {
                                connection = null;
                                connectionState = "idle";
                            }
                        });
                        attempt.trySuccess(channel);
                    });
        });
        return attempt;
    }

    private void checkUnresponsiveConnection(QuicChannel parent, long receivedBefore, long sentBefore, String phase) {
        if (receivedBefore < 0 || sentBefore < 0 || connection != parent || !parent.isActive()) return;
        parent.collectStats().addListener(done -> {
            if (!done.isSuccess() || connection != parent || !parent.isActive()) return;
            QuicConnectionStats stats = (QuicConnectionStats) done.getNow();
            // 单个目标慢、或流额度已用完都不能作为关闭共享连接的依据。
            // 等待流额度和 CONNECT 响应都要检查；仅在整个等待期间有发包却完全无回包时淘汰疑似失效连接。
            if (stats.recv() == receivedBefore && stats.sent() > sentBefore) {
                LOGGER.warn("{}期间 QUIC 连接无回包，关闭连接供后续请求重连：服务端={}，连接 ID={}，发送包增量={}",
                        phase, server, parent.id().asShortText(), stats.sent() - sentBefore);
                connection = null;
                connectionState = "failed";
                lastError = "服务端连接无响应，后续请求将重新连接";
                parent.close();
            }
        });
    }

    private final class ConnectResponse extends ChannelInboundHandlerAdapter {
        private final Promise<QuicStreamChannel> result;
        private ScheduledFuture<?> timeout;
        private final Authority target;
        private final boolean udpTunnel;
        private final DnsTunnel dns;
        private long receivedBefore = -1;
        private long sentBefore = -1;
        ConnectResponse(Promise<QuicStreamChannel> result, Authority target, boolean udpTunnel, DnsTunnel dns) {
            this.result = result; this.target = target; this.udpTunnel = udpTunnel; this.dns = dns;
        }
        private void observeConnection(QuicChannel parent) {
            receivedBefore = sentBefore = -1;
            parent.collectStats().addListener(done -> {
                if (done.isSuccess()) {
                    QuicConnectionStats stats = (QuicConnectionStats) done.getNow();
                    receivedBefore = stats.recv(); sentBefore = stats.sent();
                }
            });
        }
        @Override public void handlerAdded(ChannelHandlerContext ctx) {
            ctx.pipeline().addFirst("streamCleanup", new QuicStreamCleanupHandler());
            QuicStreamChannel stream = (QuicStreamChannel) ctx.channel();
            QuicChannel parent = stream.parent();
            observeConnection(parent);
            timeout = ctx.executor().schedule(() -> {
                checkUnresponsiveConnection(parent, receivedBefore, sentBefore, "等待 CONNECT 响应");
                result.tryFailure(new IOException("等待 CONNECT 响应超时：目标=" + target
                        + "，连接 ID=" + parent.id().asShortText() + "，流 ID=" + stream.streamId()));
                Transport.abort(stream);
            }, config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof Http3HeadersFrame headers) {
                String status = String.valueOf(headers.headers().status());
                if (status.startsWith("1")) return;
                if (status.length() == 3 && status.charAt(0) == '2') {
                    if (udpTunnel && !UdpTunnel.requested(headers.headers().getAll(UdpTunnel.HEADER))) {
                        result.tryFailure(new IOException("服务端未确认 UDP 隧道")); ctx.close(); return;
                    }
                    if (dns != null && !dns.confirmed(headers.headers().getAll(DnsTunnel.HEADER))) {
                        result.tryFailure(new IOException("服务端未确认系统 DNS 隧道，请更新服务端")); ctx.close(); return;
                    }
                    if (ctx.channel().parent() == connection) lastError = "";
                    timeout.cancel(false);
                    ctx.channel().config().setAutoRead(false);
                    ctx.pipeline().replace(this, "data", new H3DataCodec());
                    if (!result.trySuccess((QuicStreamChannel) ctx.channel())) ctx.close();
                } else {
                    // 认证失败影响整个代理；目标连接失败只属于当前请求。
                    if (status.equals("407") && ctx.channel().parent() == connection) lastError = "代理账号或密码验证失败";
                    result.tryFailure(new IOException("代理 CONNECT 失败：" + status)); ctx.close();
                }
            } else if (msg instanceof Http3UnknownFrame) ReferenceCountUtil.release(msg);
            else { ReferenceCountUtil.release(msg); result.tryFailure(new IOException("CONNECT 响应无效")); ctx.close(); }
        }
        @Override public void handlerRemoved(ChannelHandlerContext ctx) { if (timeout != null) timeout.cancel(false); }
        @Override public void channelInactive(ChannelHandlerContext ctx) {
            result.tryFailure(new IOException("CONNECT 流已关闭")); ctx.fireChannelInactive();
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { result.tryFailure(cause); ctx.close(); }
    }

    public long connectionCount() { return connectionCount.get(); }
    @Override public void close() {
        Runnable shutdown = () -> {
            closed = true;
            if (connecting != null) connecting.tryFailure(new IOException("代理会话已关闭"));
            if (connection != null) connection.close();
            udp.close();
        };
        if (loop.inEventLoop()) shutdown.run(); else loop.submit(shutdown).syncUninterruptibly();
    }
}
