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
    private final TrafficStatistics traffic = new TrafficStatistics();
    private io.netty.util.concurrent.ScheduledFuture<?> trafficSampler;
    private final java.util.function.Consumer<java.util.Map<String, Object>> trafficRecorder, accessRecorder;
    public TrafficStatistics traffic() { return traffic; }

    public LocalProxyServer(KernelConfig config) { this(config, null, null); }
    public LocalProxyServer(KernelConfig config, java.util.function.Consumer<java.util.Map<String, Object>> trafficRecorder,
                            java.util.function.Consumer<java.util.Map<String, Object>> accessRecorder) {
        this.initial = config; this.config = config.local();
        this.trafficRecorder = trafficRecorder; this.accessRecorder = accessRecorder;
    }
    public void apply(KernelConfig next) throws Exception {
        if (!config.get("bind", "127.0.0.1").equals(next.local().get("bind", "127.0.0.1"))
                || config.integer("port", 8080, 0, 65535) != next.local().integer("port", 8080, 0, 65535))
            throw new IllegalArgumentException("修改本地监听需要重启代理");
        DirectRoutes updated = DirectRoutes.load(next.local());
        session.apply(next, () -> {
            config = next.local(); routes = updated;
            // 浏览器连接和路由器共用当前唯一的 EventLoop，无需另建会话集合。
            for (Channel browser : clients) {
                LocalSession local = browser.attr(LocalSession.KEY).get();
                if (local != null) local.apply(updated);
            }
        });
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
                            ch.pipeline().addLast("proxy", new LocalRequestHandler(config, session, resolver, () -> routes, traffic, accessRecorder));
                        }
                    }).bind(new InetSocketAddress(config.get("bind", "127.0.0.1"),
                            config.integer("port", 8080, 0, 65535))).sync().channel();
            traffic.recordTo(trafficRecorder);
            trafficSampler = group.next().scheduleAtFixedRate(traffic::sample, 1, 1, TimeUnit.SECONDS);
            return this;
        } catch (Exception e) { close(); throw e; }
    }
    public InetSocketAddress address() { return (InetSocketAddress) listener.localAddress(); }
    public int activeTunnels() { return session.activeTunnels(); }
    public int pendingTunnels() { return session.pendingTunnels(); }
    /** 浏览器请求包含代理流和直连 TCP 连接；空闲的本地套接字不计入隧道。 */
    public java.util.List<java.util.Map<String, Object>> tunnels() {
        return group.next().submit(() -> {
            var result = new java.util.ArrayList<java.util.Map<String, Object>>();
            for (Channel browser : clients) {
                LocalSession local = browser.attr(LocalSession.KEY).get();
                if (browser.isActive() && local != null && !local.isClosed()) result.add(local.snapshot(session.config()));
            }
            result.sort(java.util.Comparator.<java.util.Map<String, Object>, Long>comparing(item -> (Long) item.get("createdAt"))
                    .thenComparing(item -> (String) item.get("id")));
            return java.util.List.copyOf(result);
        }).syncUninterruptibly().getNow();
    }
    public io.netty.util.concurrent.Future<Double> latency() { return session.latency(); }
    public long connectionCount() { return session.connectionCount(); }
    public String connectionState() { return session.connectionState(); }
    public String lastError() { return session.lastError(); }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        if (trafficSampler != null) trafficSampler.cancel(false);
        if (listener != null) listener.close().awaitUninterruptibly();
        clients.close().awaitUninterruptibly();
        if (session != null) session.close();
        resolver.close();
        group.shutdownGracefully(0, 2, TimeUnit.SECONDS).awaitUninterruptibly();
        traffic.stop();
    }
}
