package com.blacicada.control;

import com.blacicada.common.*;
import com.blacicada.io.KernelDatabase;
import com.blacicada.io.StorageConfig;

import java.sql.SQLException;

import com.blacicada.config.KernelConfig;
import com.blacicada.config.DirectRoutes;
import com.google.gson.*;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * Web 控制的业务入口；配置变更串行处理，网络测试独立执行。
 */
public final class KernelControl implements AutoCloseable {
    private final KernelDatabase database;
    private final ConfigurationEditor editor;
    private final ControlEvents events = new ControlEvents();
    private final ControlLogs logs;
    private final ControlTasks tasks;
    private final ScheduledExecutorService publisher = Executors.newSingleThreadScheduledExecutor();
    private KernelConfig config;
    private final ProxyRuntime runtime;
    private final HistoryRecorder history;
    private long revision, networkGeneration;
    private String previousState = "";
    private volatile List<String> secrets = List.of();
    private boolean closed, storageFailed;
    private String tunSession = "", tunState = "off", tunError = "", tunEngine = "outline";
    private long tunHeartbeat;
    private static final Gson JSON = new Gson();

    public KernelControl(Path file) throws IOException {
        this(StorageConfig.sqlite(file));
    }

    public KernelControl(StorageConfig storage) throws IOException {
        database = new KernelDatabase(storage);
        history = new HistoryRecorder(database);
        editor = new ConfigurationEditor(database.directory());
        try {
            var stored = database.read();
            config = stored.configuration();
            revision = stored.revision();
            runtime = new ProxyRuntime(history);
        } catch (IOException | RuntimeException e) {
            database.close();
            publisher.shutdownNow();
            throw e;
        }
        updateSecrets(config);
        logs = new ControlLogs(events, this::redact);
        tasks = new ControlTasks(events);
        publisher.scheduleWithFixedDelay(() -> {
            try {
                publishStatus();
            } catch (RuntimeException ignored) {
            }
        }, 0, 250, TimeUnit.MILLISECONDS);
    }

    public ControlEvents events() {
        return events;
    }

    public ControlLogs logs() {
        return logs;
    }

    public ControlTasks tasks() {
        return tasks;
    }

    public String redact(String text) {
        for (String secret : secrets) text = text.replace(secret, "***");
        return text;
    }

    private void updateSecrets(KernelConfig next) {
        Set<String> all = new LinkedHashSet<>(secrets);
        for (var p : next.connections()) all.add(p.config().required("password"));
        secrets = List.copyOf(all);
    }

    public synchronized Map<String, Object> info() {
        return Map.of("name", "network", "version", "1.0-SNAPSHOT", "apiVersion", 1, "storageBackend", database.backend(),
                "capabilities", List.of("http2", "http3", "multiConnection", "immediateSwitch", "hotSettings", "hotRoutes", "hotProfiles", "events", "logs", "asyncTests", "tunnels", "targetRoutes", "routingMode", "overviewTests", "sqlite", "postgresql", "mysql", "routingImportExport", "profileExport", "traffic", "persistentHistory", "macosTun"));
    }

    public synchronized Map<String, Object> metadata() {
        return Map.of("revision", revision,
                "requiresProxyRestart", runtime.requiresRestart(config));
    }

    public synchronized Map<String, Object> status() {
        Map<String, Object> result = new LinkedHashMap<>(metadata());
        result.put("running", runtime.isRunning());
        result.put("routingMode", config.routingMode());
        result.put("networkGeneration", networkGeneration);
        result.put("connection", runtime.state());
        result.put("error", redact(runtime.lastError()));
        result.put("address", runtime.address());
        result.put("tun", Map.of("state", tunState, "error", tunError, "engine", tunEngine, "interfaceIndex", runtime.interfaceIndex()));
        result.put("defaultConnectionId", config.defaultConnectionId());
        result.put("tunnels", tunnels());
        result.put("traffic", runtime.traffic());
        result.put("historyStorage", history.status());
        result.put("connections", config.connections().stream().map(p -> Map.of("id", p.id(), "name", p.name(),
                "protocol", p.config().get("protocol", "http3"),
                "state", active(p.id()) ? runtime.state() : "idle",
                "activeTunnels", active(p.id()) ? runtime.activeTunnels() : 0,
                "pendingTunnels", active(p.id()) ? runtime.pendingTunnels() : 0)).toList());
        return result;
    }

    private boolean active(String id) {
        return runtime.isRunning() && id.equals(config.defaultConnectionId());
    }

    public synchronized List<Map<String, Object>> tunnels() {
        return runtime.tunnels();
    }

    public synchronized Map<String, Object> traffic() {
        return runtime.traffic();
    }

    /**
     * 时间范围由内核所在时区确定，客户端不自行计算日历边界。
     */
    public synchronized Map<String, Object> trafficSeries(boolean hourly) throws SQLException {
        ensureOpen();
        history.tick();
        return database.trafficSeries(System.currentTimeMillis(), java.time.ZoneId.systemDefault(), hourly);
    }

    public synchronized Map<String, Object> history(int limit, String filter, boolean failedOnly, String order, boolean ascending, long before, String afterHost) throws SQLException {
        ensureOpen();
        if (before < 0 || limit < 1 || limit > 500 || filter.length() > 255 || afterHost.length() > 255 || !Set.of("recent", "count", "host", "failure").contains(order))
            throw new ControlException(400, "INVALID_QUERY", "访问统计查询范围或排序无效");
        return database.accessHistory(limit, filter, failedOnly, order, ascending, before, afterHost);
    }

    /**
     * 订阅快照与状态事件均携带最新速率；区间流量通过独立接口读取。
     */
    public synchronized Map<String, Object> snapshot() {
        var result = status();
        result.put("traffic", traffic());
        return result;
    }

    public synchronized JsonObject configuration() {
        JsonObject result = config.json(false);
        for (JsonElement item : result.getAsJsonArray("connections"))
            item.getAsJsonObject().addProperty("hasPassword", true);
        return result;
    }

    public synchronized JsonObject settings() {
        return config.json(false).getAsJsonObject("local");
    }

    public synchronized JsonObject profile(String id) {
        find(id);
        for (JsonElement item : configuration().getAsJsonArray("connections"))
            if (item.getAsJsonObject().get("id").getAsString().equals(id)) return item.getAsJsonObject();
        throw new IllegalStateException();
    }

    private void checkRevision(long expected) {
        ensureOpen();
        if (expected != revision) throw new ControlException(409, "REVISION_CONFLICT", "配置已变化，请重新读取后再提交");
    }

    private void ensureOpen() {
        if (storageFailed)
            throw new ControlException(503, "STORAGE_UNAVAILABLE", "数据库事务恢复失败，请重启内核检查数据库");
        if (closed) throw new ControlException(503, "KERNEL_STOPPING", "代理内核正在退出");
    }

    private KernelConfig.Profile find(String id) {
        return ConfigurationEditor.find(config, id);
    }

    public synchronized Map<String, Object> validate(JsonObject input) {
        KernelConfig next = editor.parse(input, config);
        return Map.of("valid", true, "profileCount", next.connections().size());
    }

    public synchronized void configure(JsonObject input, long expected) throws Exception {
        checkRevision(expected);
        apply(editor.parse(input, config));
    }

    private void apply(KernelConfig next) throws Exception {
        if (!tunSession.isEmpty() && runtime.requiresRestart(next))
            throw new ControlException(409, "TUN_ACTIVE", "请先关闭虚拟网卡，再修改本地监听地址或端口");
        boolean applied = false;
        try {
            database.stage(next, revision);
            invalidateNetwork();
            runtime.apply(next);
            applied = true;
            database.commit();
        } catch (Exception failure) {
            try {
                database.rollback();
            } catch (SQLException rollback) {
                failure.addSuppressed(rollback);
                storageFailed = true;
                runtime.stop();
            }
            if (applied && !storageFailed) {
                try {
                    runtime.apply(config);
                } catch (Exception rollback) {
                    failure.addSuppressed(rollback);
                    runtime.stop();
                    publishStatus();
                    throw new ControlException(503, "CONFIGURATION_ROLLBACK_FAILED", "保存失败且运行配置未能恢复，代理已停止；请检查后重新启动代理");
                }
            }
            publishStatus();
            if (failure instanceof SQLException || failure instanceof IOException)
                throw new ControlException(503, "DATABASE_WRITE_FAILED", "数据库写入失败，修改未保存；请检查数据库连接、存储空间、权限或占用情况");
            throw failure;
        }
        config = next;
        updateSecrets(next);
        revision++;
        events.emit("configuration", metadata());
        publishStatus();
    }

    public synchronized String createProfile(JsonObject item, long expected) throws Exception {
        checkRevision(expected);
        var created = editor.create(config, item);
        apply(created.configuration());
        return created.id();
    }

    public synchronized void patchProfile(String id, JsonObject patch, long expected) throws Exception {
        checkRevision(expected);
        apply(editor.patchProfile(config, id, patch));
    }

    public synchronized void removeProfile(String id, long expected) throws Exception {
        checkRevision(expected);
        find(id);
        if (config.connections().size() == 1 && !runtime.isRunning()) {
            apply(new KernelConfig(config.local(), List.of(), ""));
            return;
        }
        if (id.equals(config.defaultConnectionId()))
            throw new ControlException(409, "DEFAULT_PROFILE_IN_USE", "请先切换默认连接", "profileId");
        apply(config.remove(id));
    }

    public synchronized void select(String id, long expected) throws Exception {
        checkRevision(expected);
        find(id);
        if (!id.equals(config.defaultConnectionId())) apply(config.select(id));
    }

    public synchronized void disconnect(String id) throws Exception {
        find(id);
        if (active(id)) {
            invalidateNetwork();
            runtime.disconnect();
        }
        publishStatus();
    }

    public synchronized void patchSettings(JsonObject patch, long expected) throws Exception {
        checkRevision(expected);
        apply(editor.patchSettings(config, patch));
    }

    public synchronized Map<String, Object> routing() throws IOException {
        var routes = runtime.routes(config);
        return Map.of("mode", config.routingMode(), "defaultConnectionId", config.defaultConnectionId(), "directRules", routes.text(), "targetRoutes", routes.overrides());
    }

    public synchronized void mode(String mode, long expected) throws Exception {
        checkRevision(expected);
        if (!Set.of("rules", "direct", "proxy").contains(mode))
            throw new ControlException(400, "INVALID_MODE", "模式必须为 rules、direct 或 proxy", "mode");
        if (mode.equals(config.routingMode())) return;
        JsonObject patch = new JsonObject();
        patch.addProperty("routingMode", mode);
        patchSettings(patch, expected);
    }

    private void invalidateNetwork() {
        networkGeneration++;
        tasks.cancelNetwork();
    }

    private Map<String, Object> networkContext(String kind) {
        return Map.of("kind", kind, "generation", networkGeneration, "mode", config.routingMode(), "profileId", config.defaultConnectionId());
    }

    public synchronized Map<String, Object> networkTest(String kind) {
        ensureOpen();
        var proxy = runtime.runningProxy();
        var context = networkContext(kind);
        return switch (kind) {
            case "websites" -> tasks.websites(runtime.probeAddress(), context);
            case "exit-ip" -> tasks.exitIp(runtime.probeAddress(), context);
            case "latency" -> {
                if (config.routingMode().equals("direct"))
                    throw new ControlException(409, "DIRECT_MODE", "直连模式未使用代理连接");
                yield tasks.latency(proxy::latency, context);
            }
            default -> throw new ControlException(400, "INVALID_TEST", "未知概览测试类型");
        };
    }

    /**
     * 只修改精确目标规则，保留直连规则原文。
     */
    public synchronized void routeTarget(String target, String route, long expected) throws Exception {
        checkRevision(expected);
        if (!Set.of("proxy", "direct", "auto").contains(route))
            throw new ControlException(400, "INVALID_ROUTE", "路由必须为 proxy、direct 或 auto", "route");
        String host = DirectRoutes.normalizeHost(Authority.parse(target, -1).host());
        var overrides = new TreeMap<>(runtime.routes(config).overrides());
        if (route.equals("auto")) overrides.remove(host);
        else overrides.put(host, route);
        if (overrides.equals(runtime.routes(config).overrides())) return;
        JsonObject patch = new JsonObject();
        patch.addProperty("routesOverrides", overrides.entrySet().stream()
                .map(entry -> entry.getValue() + " " + entry.getKey()).collect(java.util.stream.Collectors.joining("\n")));
        patchSettings(patch, expected);
    }

    public static void validateRules(String rules) {
        try {
            new DirectRoutes(rules);
        } catch (IOException e) {
            throw new ControlException(400, "INVALID_RULE", e.getMessage(), "rules");
        }
    }

    public synchronized void updateRules(String rules, long expected) throws Exception {
        checkRevision(expected);
        validateRules(rules);
        JsonObject patch = new JsonObject();
        patch.addProperty("routesInline", rules);
        patchSettings(patch, expected);
    }

    /**
     * 路由文件只包含规则，不携带运行模式、默认连接或凭据。
     */
    private static JsonObject routingDocument(KernelConfig config) throws IOException {
        JsonObject result = new JsonObject();
        result.addProperty("version", 2);
        result.addProperty("kind", "network-routes");
        result.addProperty("directRules", config.local().get("routesInline", ""));
        result.add("targetRoutes", JSON.toJsonTree(DirectRoutes.load(config.local()).overrides()));
        return result;
    }

    public synchronized JsonObject exportRouting() throws IOException {
        ensureOpen();
        return routingDocument(config);
    }

    public synchronized JsonObject previewRouting(JsonObject document, String strategy, long expected) throws IOException {
        checkRevision(expected);
        return routingDocument(editor.importRouting(config, document, strategy));
    }

    public synchronized void importRouting(JsonObject document, String strategy, long expected) throws Exception {
        checkRevision(expected);
        apply(editor.importRouting(config, document, strategy));
    }

    /**
     * 密码只通过显式导出操作返回，不进入普通配置快照或事件。
     */
    public synchronized JsonObject exportProfiles(JsonObject request) {
        ensureOpen();
        if (!request.keySet().equals(Set.of("ids", "includePassword")) || !request.get("ids").isJsonArray()
                || !request.get("includePassword").isJsonPrimitive() || !request.getAsJsonPrimitive("includePassword").isBoolean())
            throw new ControlException(400, "INVALID_EXPORT", "请选择连接及密码导出选项");
        var ids = new LinkedHashSet<String>();
        for (var id : request.getAsJsonArray("ids")) {
            find(id.getAsString());
            ids.add(id.getAsString());
        }
        if (ids.isEmpty()) throw new ControlException(400, "INVALID_EXPORT", "请至少选择一个连接");
        var profiles = new JsonArray();
        for (var value : config.json(request.get("includePassword").getAsBoolean()).getAsJsonArray("connections")) {
            var profile = value.getAsJsonObject();
            if (ids.contains(profile.get("id").getAsString())) {
                profile.remove("id");
                profiles.add(profile);
            }
        }
        var result = new JsonObject();
        result.addProperty("version", 1);
        result.addProperty("kind", "network-connections");
        result.add("connections", profiles);
        return result;
    }

    public synchronized Map<String, Object> resolve(String target) throws Exception {
        Authority address = Authority.parse(target, -1);
        return tasks.resolve(address, runtime.routes(config), config.defaultConnectionId(), new OutboundNetwork(runtime.interfaceIndex()));
    }

    public synchronized Map<String, Object> test(String id, String target) {
        return tasks.start(find(id), Authority.parse(target, -1), new OutboundNetwork(runtime.interfaceIndex()));
    }

    public synchronized void start() throws Exception {
        ensureOpen();
        if (tunState.equals("stopping")) throw new ControlException(409, "TUN_STOPPING", "请等待虚拟网卡清理完成");
        if (!runtime.isRunning()) {
            invalidateNetwork();
            runtime.start(config);
        }
        publishStatus();
    }

    public synchronized void stop() {
        stopTun();
        invalidateNetwork();
        runtime.stop();
        history.finish();
        publishStatus();
    }

    public synchronized void restart() throws Exception {
        if (!tunSession.isEmpty()) throw new ControlException(409, "TUN_ACTIVE", "请先关闭虚拟网卡，再重启代理");
        stop();
        start();
    }

    private synchronized void publishStatus() {
        if (closed) return;
        checkTunHeartbeat();
        if (!storageFailed) history.tick();
        Map<String, Object> state = status();
        String encoded = JSON.toJson(state);
        if (!encoded.equals(previousState)) {
            previousState = encoded;
            events.emit("status", state);
        }
    }

    /**
     * 授权和路由安装有独立的等待预算；失联时先停止出口，再使旧会话失效。
     */
    private void checkTunHeartbeat() {
        if (tunSession.isEmpty()) return;
        long timeoutSeconds = switch (tunState) {
            case "authorizing" -> 120;
            case "starting" -> 30;
            default -> 10;
        };
        if (System.nanoTime() - tunHeartbeat <= TimeUnit.SECONDS.toNanos(timeoutSeconds)) return;

        if (tunState.equals("authorizing")) {
            tunError = "虚拟网卡授权已超时，请重新开启";
        } else {
            runtime.stop();
            try {
                runtime.bindInterface(0, config);
            } catch (Exception ignored) {
            }
            tunError = "虚拟网卡辅助进程已失联，代理已停止，请重新开启";
        }
        tunSession = "";
        tunState = "failed";
    }

    @Override
    public synchronized void close() {
        if (closed) return;
        closed = true;
        publisher.shutdownNow();
        tasks.close();
        runtime.close();
        history.finish();
        logs.close();
        events.close();
        database.close();
    }

    /**
     * 辅助进程先绑定内核出口，成功后才允许安装接管路由。
     */
    public synchronized Map<String, Object> requestTun(String engine) {
        ensureOpen();
        if (!Set.of("outline", "tun2socks").contains(engine))
            throw new ControlException(400, "INVALID_TUN_ENGINE", "TUN 转发组件无效");
        if (!System.getProperty("os.name").startsWith("Mac"))
            throw new ControlException(400, "UNSUPPORTED_PLATFORM", "虚拟网卡仅支持 macOS");
        if (!tunSession.isEmpty()) throw new ControlException(409, "TUN_ACTIVE", "虚拟网卡正在运行或清理");
        if (!runtime.isRunning()) throw new ControlException(409, "PROXY_STOPPED", "请先开启代理");
        tunEngine = engine;
        tunSession = UUID.randomUUID().toString();
        tunState = "authorizing";
        tunError = "";
        tunHeartbeat = System.nanoTime();
        publishStatus();
        return Map.of("ticket", tunSession);
    }

    public synchronized Map<String, Object> prepareTun(String interfaceName, String ticket) throws Exception {
        ensureOpen();
        if (!tunState.equals("authorizing") || !tunSession.equals(ticket))
            throw new ControlException(409, "TUN_CANCELLED", "虚拟网卡启动已取消或失效");
        if (!runtime.isRunning()) throw new ControlException(409, "PROXY_STOPPED", "请先开启代理");
        var network = java.net.NetworkInterface.getByName(interfaceName);
        if (network == null || !network.isUp() || network.isLoopback() || network.isPointToPoint() || interfaceName.startsWith("utun"))
            throw new ControlException(400, "INVALID_INTERFACE", "需要可用的真实网络接口");
        if (!runtime.probeAddress().getAddress().isLoopbackAddress())
            throw new ControlException(400, "INVALID_LISTENER", "虚拟网卡需要本地代理监听回环地址或通配地址");
        new OutboundNetwork(network.getIndex());
        tasks.cancelAll();
        invalidateNetwork();
        try {
            runtime.bindInterface(network.getIndex(), config);
        } catch (Exception e) {
            runtime.bindInterface(0, config);
            throw e;
        }
        tunState = "starting";
        tunError = "";
        tunHeartbeat = System.nanoTime();
        var address = runtime.probeAddress();
        return Map.of("session", tunSession, "proxy", new Authority(address.getHostString(), address.getPort()).toString(), "engine", tunEngine);
    }

    public synchronized Map<String, Object> heartbeatTun(String session, boolean ready) {
        if (tunSession.isEmpty() || !tunSession.equals(session))
            throw new ControlException(409, "TUN_SESSION_CHANGED", "虚拟网卡会话已失效");
        tunHeartbeat = System.nanoTime();
        if (ready && tunState.equals("starting")) tunState = "running";
        return Map.of("stop", tunState.equals("stopping") || !runtime.isRunning());
    }

    public synchronized void stopTun() {
        if (tunState.equals("authorizing")) {
            tunSession = "";
            tunState = "off";
        } else if (!tunSession.isEmpty()) tunState = "stopping";
    }

    public synchronized void finishTun(String session, String error) throws Exception {
        if (tunSession.isEmpty() || !tunSession.equals(session)) return;
        // 辅助进程只有在关闭 utun、移除路由后才能调用此方法。
        tasks.cancelAll();
        invalidateNetwork();
        runtime.bindInterface(0, config);
        tunSession = "";
        tunState = error.isEmpty() ? "off" : "failed";
        tunError = error;
        publishStatus();
    }
}
