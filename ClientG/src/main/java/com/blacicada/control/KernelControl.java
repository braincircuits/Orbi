package com.blacicada.control;

import com.blacicada.common.h3.*;
import com.blacicada.config.KernelConfig;
import com.blacicada.h3.*;
import com.google.gson.*;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Web 控制的业务入口；配置变更串行处理，网络测试独立执行。 */
public final class KernelControl implements AutoCloseable {
    private final Path configFile;
    private final ControlEvents events = new ControlEvents();
    private final ControlLogs logs;
    private final ControlTasks tasks;
    private final ScheduledExecutorService publisher = Executors.newSingleThreadScheduledExecutor();
    private KernelConfig config;
    private LocalProxyServer proxy;
    private long revision, savedRevision;
    private String previousState = "";
    private volatile List<String> secrets = List.of();
    private boolean closed;
    private static final Gson JSON = new Gson();

    public KernelControl(Path file) throws IOException {
        configFile = file.toAbsolutePath().normalize();
        config = Files.exists(configFile) ? KernelConfig.load(configFile)
                : new KernelConfig(new ProxyConfig(new Properties(), configFile.getParent()), List.of(), "");
        revision = savedRevision = Files.exists(configFile) ? 1 : 0;
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
                "capabilities", List.of("http2", "http3", "multiConnection", "immediateSwitch", "hotSettings", "hotRoutes", "hotProfiles", "events", "logs", "asyncTests"));
    }
    public synchronized Map<String, Object> metadata() {
        return Map.of("revision", revision, "savedRevision", savedRevision, "dirty", revision != savedRevision,
                "requiresProxyRestart", requiresRestart());
    }
    private boolean requiresRestart() {
        if (proxy == null) return false;
        ProxyConfig active = proxy.configuration().local();
        return !active.get("bind", "127.0.0.1").equals(config.local().get("bind", "127.0.0.1"))
                || active.integer("port", 8080, 0, 65535) != config.local().integer("port", 8080, 0, 65535);
    }
    public synchronized Map<String, Object> status() {
        Map<String, Object> result = new LinkedHashMap<>(metadata());
        result.put("running", proxy != null);
        result.put("connection", proxy == null ? "idle" : proxy.connectionState());
        result.put("error", proxy == null ? "" : redact(proxy.lastError()));
        result.put("address", proxy == null ? "" : proxy.address().getHostString() + ":" + proxy.address().getPort());
        result.put("defaultConnectionId", config.defaultConnectionId());
        result.put("connections", config.connections().stream().map(p -> Map.of("id", p.id(), "name", p.name(),
                "protocol", p.config().get("protocol", "http3"),
                "state", active(p.id()) ? proxy.connectionState() : "idle",
                "activeTunnels", active(p.id()) ? proxy.activeTunnels() : 0,
                "pendingTunnels", active(p.id()) ? proxy.pendingTunnels() : 0)).toList());
        return result;
    }
    private boolean active(String id) { return proxy != null && id.equals(config.defaultConnectionId()); }
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
    public synchronized void checkRevision(long expected) {
        if (closed) throw new ControlException(503, "KERNEL_STOPPING", "代理内核正在退出");
        if (expected >= 0 && expected != revision) throw new ControlException(409, "REVISION_CONFLICT", "配置已变化，请重新读取后再提交");
    }
    private KernelConfig.Profile find(String id) {
        return config.connections().stream().filter(p -> p.id().equals(id)).findFirst()
                .orElseThrow(() -> new ControlException(404, "PROFILE_NOT_FOUND", "连接配置不存在", "profileId"));
    }
    private KernelConfig parse(JsonObject input) {
        JsonObject copy = input.deepCopy();
        if (copy.has("connections")) for (JsonElement element : copy.getAsJsonArray("connections")) {
            JsonObject item = element.getAsJsonObject(), values = item.getAsJsonObject("config");
            String id = item.has("id") ? item.get("id").getAsString() : "";
            if (values != null && !values.has("password")) config.connections().stream().filter(p -> p.id().equals(id)).findFirst()
                    .ifPresent(old -> values.addProperty("password", old.config().required("password")));
        }
        try { return KernelConfig.parse(copy, configFile.getParent()); }
        catch (IllegalArgumentException | IllegalStateException | NullPointerException e) {
            String message = e.getMessage() == null ? "" : e.getMessage();
            if (message.contains("协议、服务器地址和端口重复")) throw new ControlException(409, "PROFILE_DUPLICATE", "协议、服务器地址和端口重复", "connections");
            throw new ControlException(400, "INVALID_CONFIGURATION", "配置结构、字段或规则无效，请检查连接参数与证书", "configuration");
        }
    }
    public synchronized Map<String, Object> validate(JsonObject input) {
        KernelConfig next = parse(input);
        return Map.of("valid", true, "profileCount", next.connections().size());
    }
    public synchronized void configure(JsonObject input, long expected) throws Exception {
        checkRevision(expected); apply(parse(input));
    }
    private void apply(KernelConfig next) throws Exception {
        if (proxy != null) {
            if (next.connections().isEmpty()) throw new ControlException(409, "PROXY_RUNNING", "请先停止代理，再删除最后一份连接配置");
            ProxyConfig previous = proxy.configuration().local();
            boolean listenerChanged = !previous.get("bind", "127.0.0.1").equals(next.local().get("bind", "127.0.0.1"))
                    || previous.integer("port", 8080, 0, 65535) != next.local().integer("port", 8080, 0, 65535);
            if (listenerChanged) {
                // 修改监听立即断开旧连接；新监听失败时恢复旧配置，已经断开的隧道不能恢复。
                proxy.close(); proxy = null;
                try { proxy = new LocalProxyServer(next).start(); }
                catch (Exception failure) {
                    try { proxy = new LocalProxyServer(config).start(); }
                    catch (Exception rollback) {
                        publishStatus();
                        throw new ControlException(503, "LISTENER_ROLLBACK_FAILED", "新监听启动失败，旧监听也未能恢复；配置未修改，请检查端口后重新启动代理");
                    }
                    publishStatus();
                    throw new ControlException(409, "LISTENER_RESTART_FAILED", "新监听启动失败，已恢复旧监听；原有连接已断开，配置未修改");
                }
            } else proxy.apply(next);
        }
        config = next; updateSecrets(next); revision++;
        events.emit("configuration", metadata()); publishStatus();
    }
    public synchronized String createProfile(JsonObject item, long expected) throws Exception {
        checkRevision(expected);
        JsonObject copy = item.deepCopy();
        String id = copy.has("id") ? copy.get("id").getAsString() : UUID.randomUUID().toString();
        if (config.connections().stream().anyMatch(p -> p.id().equals(id))) throw new ControlException(409, "PROFILE_ID_EXISTS", "连接 ID 已存在", "id");
        copy.addProperty("id", id);
        JsonObject root = config.json(true); root.getAsJsonArray("connections").add(copy);
        if (config.connections().isEmpty()) root.addProperty("defaultConnectionId", id);
        apply(parse(root)); return id;
    }
    public synchronized void patchProfile(String id, JsonObject patch, long expected) throws Exception {
        checkRevision(expected); find(id);
        if (patch.has("id") && !id.equals(patch.get("id").getAsString())) throw new ControlException(400, "IMMUTABLE_ID", "连接 ID 不能修改", "id");
        JsonObject root = config.json(true);
        for (JsonElement element : root.getAsJsonArray("connections")) {
            JsonObject item = element.getAsJsonObject();
            if (item.get("id").getAsString().equals(id)) merge(item, patch);
        }
        apply(parse(root));
    }
    public synchronized void removeProfile(String id, long expected) throws Exception {
        checkRevision(expected); find(id);
        if (config.connections().size() == 1 && proxy == null) {
            apply(new KernelConfig(config.local(), List.of(), "")); return;
        }
        if (id.equals(config.defaultConnectionId())) throw new ControlException(409, "DEFAULT_PROFILE_IN_USE", "请先切换默认连接", "profileId");
        apply(config.remove(id));
    }
    public synchronized void select(String id, long expected) throws Exception {
        checkRevision(expected); find(id);
        if (!id.equals(config.defaultConnectionId())) apply(config.select(id));
    }
    public synchronized void disconnect(String id) throws Exception { find(id); if (active(id)) proxy.disconnect(); publishStatus(); }
    public synchronized void patchSettings(JsonObject patch, long expected) throws Exception {
        checkRevision(expected);
        JsonObject root = config.json(true); merge(root.getAsJsonObject("local"), patch); apply(parse(root));
    }
    private static void merge(JsonObject target, JsonObject patch) {
        for (var entry : patch.entrySet()) {
            if (entry.getValue().isJsonNull()) target.remove(entry.getKey());
            else if (entry.getValue().isJsonObject() && target.has(entry.getKey()) && target.get(entry.getKey()).isJsonObject())
                merge(target.getAsJsonObject(entry.getKey()), entry.getValue().getAsJsonObject());
            else target.add(entry.getKey(), entry.getValue().deepCopy());
        }
    }
    public synchronized Map<String, Object> routing() throws IOException {
        return Map.of("defaultConnectionId", config.defaultConnectionId(), "directRules", rulesText());
    }
    private String rulesText() throws IOException {
        if (config.local().values().containsKey("routesInline")) return config.local().get("routesInline", "");
        Path file = config.local().path("routesFile", "pac.txt");
        return Files.exists(file) ? Files.readString(file) : "";
    }
    public static void validateRules(String rules) {
        try { new DirectRoutes(rules); }
        catch (IOException e) { throw new ControlException(400, "INVALID_RULE", e.getMessage(), "rules"); }
    }
    public synchronized void updateRules(String rules, long expected) throws Exception {
        checkRevision(expected); validateRules(rules);
        JsonObject patch = new JsonObject(); patch.addProperty("routesInline", rules); patchSettings(patch, expected);
    }
    public synchronized void reloadRules(long expected) throws Exception {
        checkRevision(expected); apply(config);
    }
    public synchronized Map<String, Object> resolve(String target) throws Exception {
        Authority address = Authority.parse(target, -1);
        return tasks.resolve(address, new DirectRoutes(rulesText()), config.defaultConnectionId());
    }
    public synchronized Map<String, Object> test(String id, String target) {
        return tasks.start(find(id), Authority.parse(target, -1));
    }
    public synchronized void start() throws Exception {
        checkRevision(-1);
        if (proxy != null) return;
        if (config.connections().isEmpty()) throw new ControlException(409, "NO_DEFAULT_PROFILE", "请先添加连接配置");
        proxy = new LocalProxyServer(config).start(); publishStatus();
    }
    public synchronized void stop() {
        if (proxy != null) { proxy.close(); proxy = null; }
        publishStatus();
    }
    public synchronized void restart() throws Exception { stop(); start(); }
    public synchronized void save(long expected) throws IOException {
        checkRevision(expected);
        Files.createDirectories(configFile.getParent()); config.save(configFile); savedRevision = revision;
        events.emit("configuration", metadata()); publishStatus();
    }
    private synchronized void publishStatus() {
        if (closed) return;
        Map<String, Object> state = status(); String encoded = JSON.toJson(state);
        if (!encoded.equals(previousState)) { previousState = encoded; events.emit("status", state); }
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; publisher.shutdownNow(); tasks.close();
        if (proxy != null) { proxy.close(); proxy = null; }
        logs.close(); events.close();
    }
}
