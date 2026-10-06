package com.blacicada.h2;

import com.blacicada.common.h3.*;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.handler.timeout.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.concurrent.GlobalEventExecutor;
import java.net.InetSocketAddress;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.*;

/** TLS 与 ALPN 成功后才接收 HTTP/2 CONNECT。 */
public final class Http2ProxyServer implements AutoCloseable {
    private final ProxyConfig config;
    private final SslContext ssl;
    private final ProxyCredentials credentials;
    private final EventLoopGroup group = new NioEventLoopGroup(1);
    private final DnsAddressResolverGroup resolver = Transport.resolver();
    private final DefaultChannelGroup connections = new DefaultChannelGroup(GlobalEventExecutor.INSTANCE);
    private final AtomicLong accepted = new AtomicLong();
    private final AtomicBoolean closed = new AtomicBoolean();
    private Channel listener;
    private static final org.apache.logging.log4j.Logger LOG = org.apache.logging.log4j.LogManager.getLogger(Http2ProxyServer.class);

    public Http2ProxyServer(ProxyConfig config) throws Exception {
        this.config = config;
        try {
            credentials = ProxyCredentials.loadServer(config);
            ssl = SslContextBuilder.forServer(config.path("tls.cert", "certs/server.crt").toFile(),
                    config.path("tls.key", "certs/server.key").toFile()).sslProvider(SslProvider.JDK)
                    .ciphers(Http2SecurityUtil.CIPHERS, SupportedCipherSuiteFilter.INSTANCE)
                    .applicationProtocolConfig(new ApplicationProtocolConfig(ApplicationProtocolConfig.Protocol.ALPN,
                            ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                            ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2")).build();
        } catch (Exception e) { close(); throw e; }
    }
    public Http2ProxyServer start() throws InterruptedException {
        try {
            listener = new ServerBootstrap().group(group).channel(NioServerSocketChannel.class)
                    .childOption(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override protected void initChannel(SocketChannel ch) {
                            connections.add(ch);
                            var tls = ssl.newHandler(ch.alloc());
                            tls.setHandshakeTimeoutMillis(config.connectTimeoutMillis());
                            ch.pipeline().addLast(tls);
                            ch.pipeline().addLast(new ApplicationProtocolNegotiationHandler("") {
                                @Override protected void configurePipeline(ChannelHandlerContext ctx, String protocol) {
                                    if (!protocol.equals("h2")) { ctx.close(); return; }
                                    accepted.incrementAndGet();
                                    var peer = ch.remoteAddress();
                                    LOG.info("与代理内核的 HTTP/2 连接成功：地址={}，连接 ID={}", peer, ch.id().asShortText());
                                    ch.closeFuture().addListener(f -> LOG.info("与代理内核的 HTTP/2 连接已断开：地址={}，连接 ID={}", peer, ch.id().asShortText()));
                                    ctx.pipeline().addLast(new IdleStateHandler(0, 0, config.idleTimeoutSeconds(), TimeUnit.SECONDS));
                                    ctx.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                        @Override public void userEventTriggered(ChannelHandlerContext c, Object e) {
                                            if (e instanceof IdleStateEvent) c.close(); else c.fireUserEventTriggered(e);
                                        }
                                    });
                                    ctx.pipeline().addLast(Http2FrameCodecBuilder.forServer().initialSettings(new Http2Settings()
                                            .maxConcurrentStreams(config.maxStreams()).maxHeaderListSize(Transport.MAX_HEADER_SIZE)
                                            .initialWindowSize(256 * 1024)).build());
                                    ctx.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Http2StreamChannel>() {
                                        @Override protected void initChannel(Http2StreamChannel stream) {
                                            stream.config().setWriteBufferWaterMark(Transport.WATERMARK);
                                            stream.pipeline().addLast(new H2ServerConnectHandler(config, credentials, resolver));
                                        }
                                    }));
                                }
                                @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { ctx.close(); }
                            });
                        }
                    }).bind(new InetSocketAddress(config.get("bind", "0.0.0.0"),
                            config.integer("http2.port", config.integer("port", 4433, 0, 65535), 0, 65535))).sync().channel();
            return this;
        } catch (RuntimeException | InterruptedException e) { close(); throw e; }
    }
    public InetSocketAddress address() { return (InetSocketAddress) listener.localAddress(); }
    public long acceptedConnections() { return accepted.get(); }
    /** 通知现有连接不再建立新流，已建立的隧道可继续传输。 */
    public void drainConnections() {
        for (Channel channel : connections) channel.writeAndFlush(new DefaultHttp2GoAwayFrame(Http2Error.NO_ERROR)).awaitUninterruptibly();
    }
    public void disconnectClients() { connections.close().awaitUninterruptibly(); }
    public void await() throws InterruptedException { listener.closeFuture().sync(); }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        if (listener != null) listener.close().awaitUninterruptibly();
        connections.close().awaitUninterruptibly();
        resolver.close();
        group.shutdownGracefully(0, 2, TimeUnit.SECONDS).awaitUninterruptibly();
    }
}
