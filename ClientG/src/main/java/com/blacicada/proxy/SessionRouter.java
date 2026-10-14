package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.DnsTunnel;
import com.blacicada.common.OutboundNetwork;
import com.blacicada.config.KernelConfig;
import io.netty.channel.*;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import io.netty.util.concurrent.*;
import java.io.IOException;
import java.util.*;

/** 管理默认代理会话、跟踪隧道，并在切换时立即关闭旧代理连接。 */
public final class SessionRouter implements AutoCloseable {
    private final EventLoop loop;
    private final DnsAddressResolverGroup resolver;
    private final OutboundNetwork network;
    private final Set<Channel> browsers = new HashSet<>();
    private final Set<Channel> tunnels = new HashSet<>();
    private volatile int activeCount, pendingCount;
    private final Set<Promise<Channel>> pending = new HashSet<>();
    private volatile KernelConfig config;
    private volatile ProxySession session;
    private boolean closed;
    public SessionRouter(EventLoop loop, DnsAddressResolverGroup resolver, KernelConfig config, OutboundNetwork network) throws Exception {
        this.network = network;
        this.loop = loop; this.resolver = resolver; this.config = config;
        session = selectedSession(config);
    }
    private ProxySession selectedSession(KernelConfig value) throws Exception {
        return value.routingMode().equals("direct") ? null : create(value.profile(value.defaultConnectionId()));
    }
    private ProxySession create(KernelConfig.Profile profile) throws Exception {
        return ProxySessionFactory.create(loop, profile.config(), resolver, network);
    }
    public Future<Channel> open(Authority target, Channel browser, boolean udp) { return open(target, browser, udp, null); }
    public Future<Channel> openDns(DnsTunnel dns, Channel browser, boolean udp) { return open(DnsTunnel.TARGET, browser, udp, dns); }
    private Future<Channel> open(Authority target, Channel browser, boolean udp, DnsTunnel dns) {
        Promise<Channel> result = loop.newPromise();
        loop.execute(() -> {
            if (closed || session == null || !browser.isActive() || result.isDone()) { result.cancel(false); return; }
            if (browsers.add(browser)) browser.closeFuture().addListener(f -> browsers.remove(browser));
            pending.add(result); pendingCount = pending.size();
            Future<? extends Channel> opening = session.open(target, udp, dns);
            result.addListener(f -> { pending.remove(result); pendingCount = pending.size(); if (!f.isSuccess()) opening.cancel(false); });
            opening.addListener(f -> {
                if (f.isSuccess()) {
                    Channel tunnel = (Channel) f.getNow();
                    if (!result.trySuccess(tunnel)) tunnel.close();
                    else {
                        tunnels.add(tunnel); activeCount = tunnels.size();
                        tunnel.closeFuture().addListener(ignored -> { tunnels.remove(tunnel); activeCount = tunnels.size(); });
                    }
                } else if (f.isCancelled()) result.cancel(false);
                else result.tryFailure(f.cause());
            });
        });
        return result;
    }
    /** 在控制线程准备新会话，事件循环内原子切换；旧隧道立即中断。 */
    public synchronized void apply(KernelConfig next, Runnable applied) throws Exception {
        KernelConfig.Profile old = config.connections().isEmpty() ? null : config.profile(config.defaultConnectionId());
        KernelConfig.Profile selected = next.connections().isEmpty() ? null : next.profile(next.defaultConnectionId());
        boolean changed = config.routingMode().equals("direct") != next.routingMode().equals("direct")
                || !next.routingMode().equals("direct") && (old == null || selected == null
                || !old.id().equals(selected.id()) || !old.config().values().equals(selected.config().values())
                || !old.config().base().equals(selected.config().base()));
        ProxySession replacement = changed ? selectedSession(next) : null;
        try {
            loop.submit(() -> {
                if (closed) throw new IllegalStateException("代理内核已停止");
                if (changed) {
                    clear(); if (session != null) session.close(); session = replacement;
                    org.apache.logging.log4j.LogManager.getLogger(SessionRouter.class).info(
                            "代理内核已切换连接，旧隧道已关闭：连接 ID={}，模式={}", selected == null ? "无" : selected.id(), next.routingMode());
                }
                config = next;
                applied.run();
            }).syncUninterruptibly();
        } catch (Exception e) { if (replacement != null) replacement.close(); throw e; }
    }
    private void clear() {
        for (Promise<Channel> request : new ArrayList<>(pending)) request.tryFailure(new IOException("代理连接已切换或断开"));
        for (Channel browser : new ArrayList<>(browsers)) browser.close();
        browsers.clear(); tunnels.clear(); activeCount = 0;
    }
    public synchronized void disconnect() throws Exception {
        ProxySession replacement = selectedSession(config);
        try { loop.submit(() -> { clear(); if (session != null) session.close(); session = replacement; }).syncUninterruptibly(); }
        catch (Exception e) { if (replacement != null) replacement.close(); throw e; }
    }
    public int activeTunnels() { return activeCount; }
    public int pendingTunnels() { return pendingCount; }
    public KernelConfig config() { return config; }
    public long connectionCount() { return session == null ? 0 : session.connectionCount(); }
    public String connectionState() { return session == null ? "unused" : session.connectionState(); }
    public String lastError() { return session == null ? "" : session.lastError(); }
    public Future<Double> latency() {
        Promise<Double> result = loop.newPromise();
        loop.execute(() -> {
            if (result.isDone()) return;
            if (closed || session == null) { result.tryFailure(new IOException("当前模式未使用代理连接")); return; }
            var measurement = session.latency();
            result.addListener(f -> { if (f.isCancelled()) measurement.cancel(false); });
            measurement.addListener(f -> {
                if (f.isSuccess()) result.trySuccess((Double) f.getNow());
                else if (f.isCancelled()) result.cancel(false);
                else result.tryFailure(f.cause());
            });
        });
        return result;
    }
    @Override public synchronized void close() {
        loop.submit(() -> { closed = true; clear(); if (session != null) session.close(); }).syncUninterruptibly();
    }
}
