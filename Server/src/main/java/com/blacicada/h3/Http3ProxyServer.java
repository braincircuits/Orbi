package com.blacicada.h3;

import com.blacicada.common.h3.*;
import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.handler.codec.http3.*;
import io.netty.handler.codec.quic.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.concurrent.GlobalEventExecutor;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import java.net.InetSocketAddress;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.atomic.AtomicLong;

public final class Http3ProxyServer implements AutoCloseable {
    private static final Logger LOGGER = LogManager.getLogger(Http3ProxyServer.class);
    private final java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean();
    private final ProxyConfig config;
    private final EventLoopGroup group;
    private final DnsAddressResolverGroup resolver;
    private final DefaultChannelGroup connections = new DefaultChannelGroup(GlobalEventExecutor.INSTANCE);
    private final AtomicLong acceptedConnections = new AtomicLong();
    private Channel listener;
    private final ChannelHandler codec;

    public Http3ProxyServer(ProxyConfig config) throws java.io.IOException {
        this.config = config;
        ProxyCredentials credentials = ProxyCredentials.loadServer(config);
        Quic.ensureAvailability();
        var ssl = QuicSslContextBuilder.forServer(config.path("tls.key", "certs/server.key").toFile(), null,
                        config.path("tls.cert", "certs/server.crt").toFile())
                .applicationProtocols(Http3.supportedApplicationProtocols()).earlyData(false).build();
        codec = Transport.limits(Http3.newQuicServerCodecBuilder(), config)
                .sslContext(ssl).sslTaskExecutor(ForkJoinPool.commonPool())
                .tokenHandler(new RetryTokenHandler())
                .handler(new ChannelInitializer<QuicChannel>() {
                    @Override protected void initChannel(QuicChannel ch) {
                        ch.pipeline().addLast("connectionLog", new ChannelInboundHandlerAdapter() {
                            private boolean connected;
                            private java.net.SocketAddress peerAddress;
                            @Override public void channelActive(ChannelHandlerContext ctx) {
                                connected = true;
                                peerAddress = ch.remoteSocketAddress();
                                LOGGER.info("与客户端的 HTTP/3 连接成功：客户端={}，连接 ID={}",
                                        peerAddress, ch.id().asShortText());
                                ctx.fireChannelActive();
                            }
                            @Override public void channelInactive(ChannelHandlerContext ctx) {
                                if (connected) LOGGER.info("与客户端的 HTTP/3 连接已断开：客户端={}，连接 ID={}",
                                        peerAddress, ch.id().asShortText());
                                ctx.fireChannelInactive();
                            }
                        });
                        connections.add(ch);
                        acceptedConnections.incrementAndGet();
                        var settings = new DefaultHttp3SettingsFrame();
                        settings.put(Http3SettingsFrame.HTTP3_SETTINGS_MAX_FIELD_SECTION_SIZE,
                                (long) Transport.MAX_HEADER_SIZE);
                        ch.pipeline().addLast(new Http3ServerConnectionHandler(
                                new ChannelInitializer<QuicStreamChannel>() {
                                    @Override protected void initChannel(QuicStreamChannel stream) {
                                        stream.config().setAllowHalfClosure(true);
                                        stream.config().setWriteBufferWaterMark(Transport.WATERMARK);
                                        stream.pipeline().addLast(new ServerConnectHandler(config, credentials, resolver));
                                    }
                                }, null, null, settings, true));
                    }
                }).build();
        group = new NioEventLoopGroup(1);
        resolver = Transport.resolver();
    }

    public Http3ProxyServer start() throws InterruptedException {
        try {
            listener = new Bootstrap().group(group).channel(NioDatagramChannel.class).handler(codec)
                    .bind(new InetSocketAddress(config.get("bind", "0.0.0.0"),
                            config.integer("port", 4433, 0, 65535))).sync().channel();
            return this;
        } catch (RuntimeException | InterruptedException e) { close(); throw e; }
    }

    public InetSocketAddress address() { return (InetSocketAddress) listener.localAddress(); }
    public long acceptedConnections() { return acceptedConnections.get(); }
    public void disconnectClients() { connections.close().awaitUninterruptibly(); }
    public void await() throws InterruptedException { listener.closeFuture().sync(); }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        connections.close().awaitUninterruptibly();
        if (listener != null) listener.close().awaitUninterruptibly();
        resolver.close();
        group.shutdownGracefully(0, 2, java.util.concurrent.TimeUnit.SECONDS).awaitUninterruptibly();
    }
}
