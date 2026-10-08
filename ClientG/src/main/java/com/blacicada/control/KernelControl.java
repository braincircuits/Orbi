package com.blacicada.control;

import com.blacicada.common.*;
import com.blacicada.config.KernelConfig;
import com.blacicada.config.DirectRoutes;
import com.google.gson.*;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Web 控制的业务入口；配置变更串行处理，网络测试独立执行。 */
public final class KernelControl implements AutoCloseable {
    private final Path configFile;
    private final ConfigurationEditor editor;
    private final ControlEvents events = new ControlEvents();
    private final ControlLogs logs;
    private final ControlTasks tasks;
    private final ScheduledExecutorService publisher = Executors.newSingleThreadScheduledExecutor();
    private KernelConfig config;
    private final ProxyRuntime runtime = new ProxyRuntime();
    private long revision, savedRevision;
    private String previousState = "";
    private volatile List<String> secrets = List.of();
    private boolean closed;
    private static final Gson JSON = new Gson();

    public KernelControl(Path file) throws IOException {
        configFile = file.toAbsolutePath().normalize();
        editor = new ConfigurationEditor(configFile.getParent());
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
                "requiresProxyRestart", runtime.requiresRestart(config));
    }
    public synchronized Map<String, Object> status() {
        Map<String, Object> result = new LinkedHashMap<>(metadata());
        result.put("running", runtime.isRunning());
        result.put("connection", runtime.state());
        result.put("error", redact(runtime.lastError()));
        result.put("address", runtime.address());
        result.put("defaultConnectionId", config.defaultConnectionId());
        result.put("connections", config.connections().stream().map(p -> Map.of("id", p.id(), "name", p.name(),
                "protocol", p.config().get("protocol", "http3"),
                "state", active(p.id()) ? runtime.state() : "idle",
                "activeTunnels", active(p.id()) ? runtime.activeTunnels() : 0,
                "pendingTunnels", active(p.id()) ? runtime.pendingTunnels() : 0)).toList());
        return result;
    }
    private boolean active(String id) { return runtime.isRunning() && id.equals(config.defaultConnectionId()); }
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
        try { runtime.apply(next); }
        catch (Exception failure) { publishStatus(); throw failure; }
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
    public synchronized void disconnect(String id) throws Exception { find(id); if (active(id)) runtime.disconnect(); publishStatus(); }
    public synchronized void patchSettings(JsonObject patch, long expected) throws Exception {
        checkRevision(expected); apply(editor.patchSettings(config, patch));
    }
    public synchronized Map<String, Object> routing() throws IOException {
        return Map.of("defaultConnectionId", config.defaultConnectionId(), "directRules", rulesText());
    }
    private String rulesText() throws IOException { return runtime.routes(config).text(); }
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
        return tasks.resolve(address, runtime.routes(config), config.defaultConnectionId());
    }
    public synchronized Map<String, Object> test(String id, String target) {
        return tasks.start(find(id), Authority.parse(target, -1));
    }
    public synchronized void start() throws Exception {
        ensureOpen();
        runtime.start(config); publishStatus();
    }
    public synchronized void stop() { runtime.stop(); publishStatus(); }
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
        runtime.close();
        logs.close(); events.close();
    }
}
