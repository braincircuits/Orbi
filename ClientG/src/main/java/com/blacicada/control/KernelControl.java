package com.blacicada.control;

import com.blacicada.common.*;
import com.blacicada.io.KernelDatabase;
import java.sql.SQLException;
import com.blacicada.config.KernelConfig;
import com.blacicada.config.DirectRoutes;
import com.google.gson.*;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Web 控制的业务入口；配置变更串行处理，网络测试独立执行。 */
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
    private static final Gson JSON = new Gson();

    public KernelControl(Path file) throws IOException {
        database = new KernelDatabase(file);
        history = new HistoryRecorder(database);
        editor = new ConfigurationEditor(database.file().getParent());
        try {
            var stored = database.read(); config = stored.configuration(); revision = stored.revision();
            runtime = new ProxyRuntime(history, database.latestTraffic());
        } catch (SQLException e) { database.close(); publisher.shutdownNow(); throw new IOException("读取流量历史失败", e);
        } catch (IOException | RuntimeException e) { database.close(); publisher.shutdownNow(); throw e; }
        updateSecrets(config);
        logs = new ControlLogs(events, this::redact);
        tasks = new ControlTasks(events);
        publisher.scheduleWithFixedDelay(() -> { try { publishStatus(); } catch (RuntimeException ignored) { } }, 0, 250, TimeUnit.MILLISECONDS);
    }
    public ControlEvents events() { return events; }
    public ControlLogs logs() { return logs; }
    public ControlTasks tasks() { return tasks; }
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
        return Map.of("name", "network", "version", "1.0-SNAPSHOT", "apiVersion", 1,
                "capabilities", List.of("http2", "http3", "multiConnection", "immediateSwitch", "hotSettings", "hotRoutes", "hotProfiles", "events", "logs", "asyncTests", "tunnels", "targetRoutes", "routingMode", "overviewTests", "sqlite", "routingImportExport", "traffic", "persistentHistory"));
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
        result.put("defaultConnectionId", config.defaultConnectionId());
        result.put("tunnels", tunnels());
        result.put("traffic", runtime.traffic(false));
        result.put("historyStorage", history.status());
        result.put("connections", config.connections().stream().map(p -> Map.of("id", p.id(), "name", p.name(),
                "protocol", p.config().get("protocol", "http3"),
                "state", active(p.id()) ? runtime.state() : "idle",
                "activeTunnels", active(p.id()) ? runtime.activeTunnels() : 0,
                "pendingTunnels", active(p.id()) ? runtime.pendingTunnels() : 0)).toList());
        return result;
    }
    private boolean active(String id) { return runtime.isRunning() && id.equals(config.defaultConnectionId()); }
    public synchronized List<Map<String, Object>> tunnels() { return runtime.tunnels(); }
    public synchronized Map<String, Object> traffic() { return runtime.traffic(true); }
    public synchronized Map<String, Object> trafficSummary(JsonObject body) throws SQLException {
        ensureOpen();
        var field = body.get("boundaries");
        if (field == null || !field.isJsonArray() || field.getAsJsonArray().size() < 2 || field.getAsJsonArray().size() > 63)
            throw new ControlException(400, "INVALID_QUERY", "统计需要 2 至 63 个递增的毫秒时间边界");
        var boundaries = new ArrayList<Long>();
        for (var value : field.getAsJsonArray()) {
            long time;
            try {
                if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber()) throw new ArithmeticException();
                time = value.getAsBigDecimal().longValueExact();
            } catch (ArithmeticException | NumberFormatException e) {
                throw new ControlException(400, "INVALID_QUERY", "统计时间必须是整数毫秒时间戳");
            }
            if (time < 0 || !boundaries.isEmpty() && time <= boundaries.getLast())
                throw new ControlException(400, "INVALID_QUERY", "统计时间边界必须非负且严格递增");
            boundaries.add(time);
        }
        if (boundaries.getLast() - boundaries.getFirst() > 32L * 86400000)
            throw new ControlException(400, "INVALID_QUERY", "单次统计范围不能超过 32 天");
        history.flush();
        return database.trafficSummary(boundaries);
    }
    public synchronized Map<String, Object> history(boolean traffic, long from, long to, long before, int limit, String filter) throws SQLException {
        ensureOpen();
        if (from < 0 || to <= from || before <= 0 || limit < 1 || limit > 500 || filter.length() > 255)
            throw new ControlException(400, "INVALID_QUERY", "历史查询范围、游标或数量无效");
        history.flush();
        return traffic ? database.trafficHistory(from, to, before, limit, filter)
                : database.accessHistory(from, to, before, limit, filter);
    }
    /** 订阅快照携带完整窗口，后续状态事件只携带最新采样。 */
    public synchronized Map<String, Object> snapshot() {
        var result = status(); result.put("traffic", traffic()); return result;
    }
    public synchronized JsonObject configuration() {
        JsonObject result = config.json(false);
        for (JsonElement item : result.getAsJsonArray("connections")) item.getAsJsonObject().addProperty("hasPassword", true);
        return result;
    }
    public synchronized JsonObject settings() { return config.json(false).getAsJsonObject("local"); }
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
        if (storageFailed) throw new ControlException(503, "STORAGE_UNAVAILABLE", "数据库事务恢复失败，请重启内核检查数据库");
        if (closed) throw new ControlException(503, "KERNEL_STOPPING", "代理内核正在退出");
    }
    private KernelConfig.Profile find(String id) { return ConfigurationEditor.find(config, id); }
    public synchronized Map<String, Object> validate(JsonObject input) {
        KernelConfig next = editor.parse(input, config);
        return Map.of("valid", true, "profileCount", next.connections().size());
    }
    public synchronized void configure(JsonObject input, long expected) throws Exception {
        checkRevision(expected); apply(editor.parse(input, config));
    }
    private void apply(KernelConfig next) throws Exception {
        boolean applied = false;
        try {
            database.stage(next, revision);
            invalidateNetwork();
            runtime.apply(next); applied = true;
            database.commit();
        } catch (Exception failure) {
            try { database.rollback(); }
            catch (SQLException rollback) { failure.addSuppressed(rollback); storageFailed = true; runtime.stop(); }
            if (applied && !storageFailed) {
                try { runtime.apply(config); }
                catch (Exception rollback) {
                    failure.addSuppressed(rollback); runtime.stop();
                    publishStatus();
                    throw new ControlException(503, "CONFIGURATION_ROLLBACK_FAILED", "保存失败且运行配置未能恢复，代理已停止；请检查后重新启动代理");
                }
            }
            publishStatus();
            if (failure instanceof SQLException || failure instanceof IOException)
                throw new ControlException(503, "DATABASE_WRITE_FAILED", "数据库写入失败，修改未保存；请检查磁盘空间、文件权限或占用情况");
            throw failure;
        }
        config = next; updateSecrets(next); revision++;
        events.emit("configuration", metadata()); publishStatus();
    }
    public synchronized String createProfile(JsonObject item, long expected) throws Exception {
        checkRevision(expected);
        var created = editor.create(config, item);
        apply(created.configuration()); return created.id();
    }
    public synchronized void patchProfile(String id, JsonObject patch, long expected) throws Exception {
        checkRevision(expected); apply(editor.patchProfile(config, id, patch));
    }
    public synchronized void removeProfile(String id, long expected) throws Exception {
        checkRevision(expected); find(id);
        if (config.connections().size() == 1 && !runtime.isRunning()) {
            apply(new KernelConfig(config.local(), List.of(), "")); return;
        }
        if (id.equals(config.defaultConnectionId())) throw new ControlException(409, "DEFAULT_PROFILE_IN_USE", "请先切换默认连接", "profileId");
        apply(config.remove(id));
    }
    public synchronized void select(String id, long expected) throws Exception {
        checkRevision(expected); find(id);
        if (!id.equals(config.defaultConnectionId())) apply(config.select(id));
    }
    public synchronized void disconnect(String id) throws Exception { find(id); if (active(id)) { invalidateNetwork(); runtime.disconnect(); } publishStatus(); }
    public synchronized void patchSettings(JsonObject patch, long expected) throws Exception {
        checkRevision(expected); apply(editor.patchSettings(config, patch));
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
        JsonObject patch = new JsonObject(); patch.addProperty("routingMode", mode); patchSettings(patch, expected);
    }
    private void invalidateNetwork() { networkGeneration++; tasks.cancelNetwork(); }
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
                if (config.routingMode().equals("direct")) throw new ControlException(409, "DIRECT_MODE", "直连模式未使用代理连接");
                yield tasks.latency(proxy::latency, context);
            }
            default -> throw new ControlException(400, "INVALID_TEST", "未知概览测试类型");
        };
    }
    /** 只修改精确目标规则，保留直连规则原文。 */
    public synchronized void routeTarget(String target, String route, long expected) throws Exception {
        checkRevision(expected);
        if (!Set.of("proxy", "direct", "auto").contains(route))
            throw new ControlException(400, "INVALID_ROUTE", "路由必须为 proxy、direct 或 auto", "route");
        String host = DirectRoutes.normalizeHost(Authority.parse(target, -1).host());
        var overrides = new TreeMap<>(runtime.routes(config).overrides());
        if (route.equals("auto")) overrides.remove(host); else overrides.put(host, route);
        if (overrides.equals(runtime.routes(config).overrides())) return;
        JsonObject patch = new JsonObject();
        patch.addProperty("routesOverrides", overrides.entrySet().stream()
                .map(entry -> entry.getValue() + " " + entry.getKey()).collect(java.util.stream.Collectors.joining("\n")));
        patchSettings(patch, expected);
    }
    public static void validateRules(String rules) {
        try { new DirectRoutes(rules); }
        catch (IOException e) { throw new ControlException(400, "INVALID_RULE", e.getMessage(), "rules"); }
    }
    public synchronized void updateRules(String rules, long expected) throws Exception {
        checkRevision(expected); validateRules(rules);
        JsonObject patch = new JsonObject(); patch.addProperty("routesInline", rules); patchSettings(patch, expected);
    }
    /** 导出可直接作为导入请求体的路由文档，不包含连接凭据。 */
    public synchronized JsonObject exportRouting() throws IOException {
        JsonObject result = JSON.toJsonTree(routing()).getAsJsonObject();
        result.addProperty("version", 1);
        return result;
    }
    public synchronized void importRouting(JsonObject document, long expected) throws Exception {
        checkRevision(expected);
        apply(editor.importRouting(config, document));
    }
    public synchronized Map<String, Object> resolve(String target) throws Exception {
        Authority address = Authority.parse(target, -1);
        return tasks.resolve(address, runtime.routes(config), config.defaultConnectionId());
    }
    public synchronized Map<String, Object> test(String id, String target) {
        return tasks.start(find(id), Authority.parse(target, -1));
    }
    public synchronized void start() throws Exception {
        ensureOpen();
        if (!runtime.isRunning()) { invalidateNetwork(); runtime.start(config); } publishStatus();
    }
    public synchronized void stop() { invalidateNetwork(); runtime.stop(); publishStatus(); }
    public synchronized void restart() throws Exception { stop(); start(); }
    private synchronized void publishStatus() {
        if (closed) return;
        if (!storageFailed) history.flush();
        Map<String, Object> state = status(); String encoded = JSON.toJson(state);
        if (!encoded.equals(previousState)) { previousState = encoded; events.emit("status", state); }
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; publisher.shutdownNow(); tasks.close();
        runtime.close();
        history.finish();
        logs.close(); events.close(); database.close();
    }
}
