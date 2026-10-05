package com.blacicada.h3;

import com.blacicada.common.h3.*;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.concurrent.GlobalEventExecutor;
import java.net.InetSocketAddress;
import java.util.concurrent.TimeUnit;

public final class LocalProxyServer implements AutoCloseable {
    private final java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean();
    private final ProxyConfig config;
    private final EventLoopGroup group = new NioEventLoopGroup(1);
    private final DnsAddressResolverGroup resolver = Transport.resolver();
    private final DefaultChannelGroup clients = new DefaultChannelGroup(GlobalEventExecutor.INSTANCE);
    private Http3Session session;
    private Channel listener;

    public LocalProxyServer(ProxyConfig config) { this.config = config; }

    public LocalProxyServer start() throws Exception {
        try {
            session = new Http3Session(group.next(), config, resolver);
            var routes = new DirectRoutes(config.path("routesFile", "pac.txt"));
            listener = new ServerBootstrap().group(group).channel(NioServerSocketChannel.class)
                    .childOption(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .childOption(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override protected void initChannel(SocketChannel ch) {
                            clients.add(ch);
                            var decoder = new HttpRequestDecoder(4096, Transport.MAX_HEADER_SIZE, 8192);
                            decoder.setSingleDecode(true);
                            ch.pipeline().addLast("responseEncoder", new HttpResponseEncoder());
                            ch.pipeline().addLast("requestDecoder", decoder);
                            ch.pipeline().addLast("proxy", new LocalRequestHandler(config, session, resolver, routes));
                        }
                    }).bind(new InetSocketAddress(config.get("bind", "127.0.0.1"),
                            config.integer("port", 8080, 0, 65535))).sync().channel();
            return this;
        } catch (Exception e) { close(); throw e; }
    }
    public InetSocketAddress address() { return (InetSocketAddress) listener.localAddress(); }
    public long connectionCount() { return session.connectionCount(); }
    public void await() throws InterruptedException { listener.closeFuture().sync(); }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        if (listener != null) listener.close().awaitUninterruptibly();
        clients.close().awaitUninterruptibly();
        if (session != null) session.close();
        resolver.close();
        group.shutdownGracefully(0, 2, TimeUnit.SECONDS).awaitUninterruptibly();
    }
}
