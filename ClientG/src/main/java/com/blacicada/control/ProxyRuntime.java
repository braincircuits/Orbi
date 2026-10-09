package com.blacicada.control;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.proxy.LocalProxyServer;
import com.blacicada.config.DirectRoutes;
import java.io.IOException;

/** 只管理本地代理生命周期；调用方通过 KernelControl 的锁串行访问。 */
final class ProxyRuntime implements AutoCloseable {
    private LocalProxyServer proxy;

    /** 运行时诊断与转发共用生效快照；停止时读取待启动的配置。 */
    DirectRoutes routes(KernelConfig config) throws IOException {
        return proxy == null ? DirectRoutes.load(config.local()) : proxy.routes();
    }
    boolean isRunning() { return proxy != null; }
    String state() { return proxy == null ? "idle" : proxy.connectionState(); }
    String lastError() { return proxy == null ? "" : proxy.lastError(); }
    String address() { return proxy == null ? "" : proxy.address().getHostString() + ":" + proxy.address().getPort(); }
    int activeTunnels() { return proxy == null ? 0 : proxy.activeTunnels(); }
    int pendingTunnels() { return proxy == null ? 0 : proxy.pendingTunnels(); }
    java.util.List<java.util.Map<String, Object>> tunnels() { return proxy == null ? java.util.List.of() : proxy.tunnels(); }
    boolean requiresRestart(KernelConfig next) {
        return proxy != null && listenerChanged(proxy.configuration().local(), next.local());
    }
    private static boolean listenerChanged(ProxyConfig old, ProxyConfig next) {
        return !old.get("bind", "127.0.0.1").equals(next.get("bind", "127.0.0.1"))
                || old.integer("port", 8080, 0, 65535) != next.integer("port", 8080, 0, 65535);
    }
    void start(KernelConfig config) throws Exception {
        if (proxy != null) return;
        if (config.connections().isEmpty()) throw new ControlException(409, "NO_DEFAULT_PROFILE", "请先添加连接配置");
        proxy = new LocalProxyServer(config).start();
    }
    void stop() {
        if (proxy != null) { proxy.close(); proxy = null; }
    }
    void disconnect() throws Exception { if (proxy != null) proxy.disconnect(); }
    void apply(KernelConfig next) throws Exception {
        if (proxy == null) return;
        if (next.connections().isEmpty()) throw new ControlException(409, "PROXY_RUNNING", "请先停止代理，再删除最后一份连接配置");
        if (!requiresRestart(next)) { proxy.apply(next); return; }
        KernelConfig previous = proxy.configuration();
        // 新监听失败时恢复旧配置；已经断开的浏览器连接无法恢复。
        stop();
        try { start(next); }
        catch (Exception failure) {
            try { start(previous); }
            catch (Exception rollback) {
                throw new ControlException(503, "LISTENER_ROLLBACK_FAILED", "新监听启动失败，旧监听也未能恢复；配置未修改，请检查端口后重新启动代理");
            }
            throw new ControlException(409, "LISTENER_RESTART_FAILED", "新监听启动失败，已恢复旧监听；原有连接已断开，配置未修改");
        }
    }
    @Override public void close() { stop(); }
}
