package com.blacicada.proxy;

import com.blacicada.config.DirectRoutes;

import com.blacicada.common.*;
import com.blacicada.config.KernelConfig;
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
    private volatile ProxyConfig config;
    private volatile DirectRoutes routes;
    private final EventLoopGroup group = new NioEventLoopGroup(1);
    private final DnsAddressResolverGroup resolver = Transport.resolver();
    private final DefaultChannelGroup clients = new DefaultChannelGroup(GlobalEventExecutor.INSTANCE);
    private SessionRouter session;
    private final KernelConfig initial;
    private Channel listener;

    public LocalProxyServer(KernelConfig config) { this.initial = config; this.config = config.local(); }
    public void apply(KernelConfig next) throws Exception {
        if (!config.get("bind", "127.0.0.1").equals(next.local().get("bind", "127.0.0.1"))
                || config.integer("port", 8080, 0, 65535) != next.local().integer("port", 8080, 0, 65535))
            throw new IllegalArgumentException("修改本地监听需要重启代理");
        DirectRoutes updated = DirectRoutes.load(next.local());
        session.apply(next, () -> { config = next.local(); routes = updated; });
    }
    public void disconnect() throws Exception { session.disconnect(); }
    public KernelConfig configuration() { return session.config(); }
    public DirectRoutes routes() { return routes; }


    public LocalProxyServer start() throws Exception {
        try {
            session = new SessionRouter(group.next(), resolver, initial);
            routes = DirectRoutes.load(config);
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
                            ch.pipeline().addLast("proxy", new LocalRequestHandler(config, session, resolver, () -> routes));
                        }
                    }).bind(new InetSocketAddress(config.get("bind", "127.0.0.1"),
                            config.integer("port", 8080, 0, 65535))).sync().channel();
            return this;
        } catch (Exception e) { close(); throw e; }
    }
    public InetSocketAddress address() { return (InetSocketAddress) listener.localAddress(); }
    public int activeTunnels() { return session.activeTunnels(); }
    public int pendingTunnels() { return session.pendingTunnels(); }
    public long connectionCount() { return session.connectionCount(); }
    public String connectionState() { return session.connectionState(); }
    public String lastError() { return session.lastError(); }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        if (listener != null) listener.close().awaitUninterruptibly();
        clients.close().awaitUninterruptibly();
        if (session != null) session.close();
        resolver.close();
        group.shutdownGracefully(0, 2, TimeUnit.SECONDS).awaitUninterruptibly();
    }
}
