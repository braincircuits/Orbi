package com.blacicada.h3;

import com.blacicada.common.h3.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.handler.codec.http3.*;
import io.netty.handler.codec.quic.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.*;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** All connection/stream allocation state is confined to a single event loop. */
public final class Http3Session implements AutoCloseable {
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

    public Http3Session(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver) throws Exception {
        this.loop = loop; this.config = config; this.resolver = resolver;
        authorization = Transport.authorization(config.required("password"));
        server = serverAddress(config);
        Quic.ensureAvailability();
        var sslBuilder = QuicSslContextBuilder.forClient().earlyData(false)
                .applicationProtocols(Http3.supportedApplicationProtocols()).endpointIdentificationAlgorithm("HTTPS");
        if (!config.get("tls.ca", "").isEmpty()) sslBuilder.trustManager(config.path("tls.ca", "").toFile());
        var ssl = sslBuilder.build();
        String serverName = config.get("tls.serverName", server.host());
        var codec = Transport.limits(Http3.newQuicClientCodecBuilder(), config)
                .sslEngineProvider(ch -> ssl.newEngine(ch.alloc(), serverName, server.port()))
                .sslTaskExecutor(ForkJoinPool.commonPool()).build();
        udp = new Bootstrap().group(loop).channel(NioDatagramChannel.class).handler(codec)
                .bind(0).sync().channel();
    }

    private static Authority serverAddress(ProxyConfig config) throws IOException {
        if (!config.get("server.host", "").isEmpty()) {
            return new Authority(config.required("server.host"), config.integer("server.port", 4433, 1, 65535));
        }
        // Compatibility with the original numbered config.txt server list.
        var lines = Files.readAllLines(config.path("serversFile", "config.txt")).stream()
                .map(String::trim).filter(s -> !s.isEmpty() && !s.startsWith("#")).toList();
        int index = Integer.parseInt(lines.getFirst().replace("[", "").replace("]", ""));
        if (index < 1 || index >= lines.size()) throw new IllegalArgumentException("Invalid server selection");
        return Authority.parse(lines.get(index), -1);
    }

    public Future<QuicStreamChannel> open(Authority target) {
        Promise<QuicStreamChannel> result = loop.newPromise();
        loop.execute(() -> {
            if (result.isDone()) return;
            if (closed || streams >= config.maxStreams()) {
                result.tryFailure(new IOException("Proxy unavailable or stream limit reached")); return;
            }
            streams++;
            acquire().addListener(f -> {
                if (result.isDone()) { streams--; return; }
                if (!f.isSuccess()) { streams--; result.tryFailure(f.cause()); return; }
                QuicChannel parent = (QuicChannel) f.getNow();
                var response = new ConnectResponse(result);
                Http3.newRequestStreamBootstrap(parent, response)
                        .option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                        .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                        .create().addListener(created -> {
                            if (!created.isSuccess()) { streams--; result.tryFailure(created.cause()); return; }
                            QuicStreamChannel stream = (QuicStreamChannel) created.getNow();
                            stream.closeFuture().addListener(ignored -> streams--);
                            result.addListener(done -> { if (!done.isSuccess()) stream.close(); });
                            var request = new DefaultHttp3HeadersFrame();
                            request.headers().method("CONNECT").authority(target.toString())
                                    .set("proxy-authorization", authorization);
                            stream.writeAndFlush(request).addListener(write -> {
                                if (!write.isSuccess()) result.tryFailure(write.cause());
                            });
                        });
            });
        });
        return result;
    }

    private Future<QuicChannel> acquire() {
        if (closed) return loop.newFailedFuture(new IOException("Proxy session closed"));
        if (connection != null && connection.isActive()) return loop.newSucceededFuture(connection);
        if (connecting != null) return connecting;
        Promise<QuicChannel> attempt = loop.newPromise();
        connecting = attempt;
        var deadline = loop.schedule(() -> attempt.tryFailure(new IOException("HTTP/3 handshake timed out")),
                config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        attempt.addListener(f -> { deadline.cancel(false); if (connecting == attempt) connecting = null; });
        resolver.getResolver(loop).resolve(server.unresolved()).addListener(resolved -> {
            if (attempt.isDone()) return;
            if (!resolved.isSuccess()) { attempt.tryFailure(resolved.cause()); return; }
            var settings = new DefaultHttp3SettingsFrame();
            settings.put(Http3SettingsFrame.HTTP3_SETTINGS_MAX_FIELD_SECTION_SIZE, (long) Transport.MAX_HEADER_SIZE);
            QuicChannel.newBootstrap(udp)
                    .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, config.connectTimeoutMillis())
                    .handler(new Http3ClientConnectionHandler(null, null, null, settings, true))
                    .remoteAddress((InetSocketAddress) resolved.getNow()).connect().addListener(connected -> {
                        if (!connected.isSuccess()) { attempt.tryFailure(connected.cause()); return; }
                        QuicChannel channel = (QuicChannel) connected.getNow();
                        if (closed || attempt.isDone()) { channel.close(); return; }
                        connection = channel;
                        connectionCount.incrementAndGet();
                        channel.closeFuture().addListener(ignored -> { if (connection == channel) connection = null; });
                        attempt.trySuccess(channel);
                    });
        });
        return attempt;
    }

    private final class ConnectResponse extends ChannelInboundHandlerAdapter {
        private final Promise<QuicStreamChannel> result;
        private ScheduledFuture<?> timeout;
        ConnectResponse(Promise<QuicStreamChannel> result) { this.result = result; }
        @Override public void handlerAdded(ChannelHandlerContext ctx) {
            timeout = ctx.executor().schedule(() -> {
                result.tryFailure(new IOException("CONNECT response timed out")); ctx.close();
            }, config.connectTimeoutMillis(), TimeUnit.MILLISECONDS);
        }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof Http3HeadersFrame headers) {
                String status = String.valueOf(headers.headers().status());
                if (status.startsWith("1")) return;
                if (status.length() == 3 && status.charAt(0) == '2') {
                    timeout.cancel(false);
                    ctx.channel().config().setAutoRead(false);
                    ctx.pipeline().replace(this, "data", new H3DataCodec());
                    if (!result.trySuccess((QuicStreamChannel) ctx.channel())) ctx.close();
                } else { result.tryFailure(new IOException("Proxy CONNECT failed: " + status)); ctx.close(); }
            } else if (msg instanceof Http3UnknownFrame) ReferenceCountUtil.release(msg);
            else { ReferenceCountUtil.release(msg); result.tryFailure(new IOException("Invalid CONNECT response")); ctx.close(); }
        }
        @Override public void handlerRemoved(ChannelHandlerContext ctx) { if (timeout != null) timeout.cancel(false); }
        @Override public void channelInactive(ChannelHandlerContext ctx) {
            result.tryFailure(new IOException("CONNECT stream closed")); ctx.fireChannelInactive();
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { result.tryFailure(cause); ctx.close(); }
    }

    public long connectionCount() { return connectionCount.get(); }
    @Override public void close() {
        loop.submit(() -> {
            closed = true;
            if (connecting != null) connecting.tryFailure(new IOException("Proxy session closed"));
            if (connection != null) connection.close();
            udp.close();
        }).syncUninterruptibly();
    }
}
