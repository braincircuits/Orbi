package com.blacicada.control;

import com.blacicada.common.h3.*;
import com.blacicada.config.KernelConfig;
import com.blacicada.h3.*;
import com.google.gson.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** 标准输入输出承载控制协议，输入关闭时释放代理资源。 */
public final class UiControl implements AutoCloseable {
    private final PrintStream output;
    private final ScheduledExecutorService events = Executors.newSingleThreadScheduledExecutor();
    private LocalProxyServer proxy;
    private KernelConfig config;
    private String previous = "";
    private boolean closed;
    private static final Gson JSON = new Gson();
    private UiControl(PrintStream output) { this.output = output; }

    public static void run(InputStream input, PrintStream output) throws IOException {
        try (var control = new UiControl(output)) {
            var hook = new Thread(control::close, "ui-control-shutdown");
            Runtime.getRuntime().addShutdownHook(hook);
            try {
                control.emit(Map.of("event", "ready", "version", 1, "capabilities",
                        List.of("multiConnection", "http2", "http3", "immediateSwitch")));
                control.events.scheduleWithFixedDelay(control::publishStatus, 0, 250, TimeUnit.MILLISECONDS);
                var reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8));
                String line;
                while ((line = reader.readLine()) != null) {
                    if (line.length() > 1_048_576) { control.emit(Map.of("event", "error", "message", "控制命令过大")); break; }
                    if (!control.handle(line)) break;
                }
            } finally { try { Runtime.getRuntime().removeShutdownHook(hook); } catch (IllegalStateException ignored) { } }
        }
    }
    private synchronized boolean handle(String line) {
        String id = "";
        try {
            JsonObject command = JsonParser.parseString(line).getAsJsonObject();
            id = command.get("id").getAsString();
            String action = command.get("command").getAsString();
            Object data = Map.of();
            switch (action) {
                case "start" -> start(command);
                case "stop", "exit" -> stop();
                case "status" -> { }
                case "validate" -> new DirectRoutes(command.get("rules").getAsString());
                case "configure" -> apply(KernelConfig.parse(command.getAsJsonObject("configuration"), Path.of(".")));
                case "config.get" -> data = requiredConfig().json(false);
                case "config.load" -> {
                    if (proxy != null) throw new IllegalStateException("加载配置文件前请停止代理内核");
                    config = KernelConfig.load(Path.of(command.get("path").getAsString()));
                }
                case "config.save" -> requiredConfig().save(Path.of(command.get("path").getAsString()));
                case "connection.upsert" -> {
                    KernelConfig current = requiredConfig();
                    JsonObject item = command.getAsJsonObject("connection");
                    String key = item.get("id").getAsString();
                    var old = current.connections().stream().filter(p -> p.id().equals(key)).findFirst().orElse(null);
                    apply(current.upsert(KernelConfig.parseProfile(item, current.local().base(), old)));
                }
                case "connection.remove" -> apply(requiredConfig().remove(command.get("connectionId").getAsString()));
                case "connection.select" -> apply(requiredConfig().select(command.get("connectionId").getAsString()));
                case "connection.disconnect" -> {
                    var current = requiredConfig();
                    String selected = command.get("connectionId").getAsString();
                    current.profile(selected);
                    if (proxy != null && current.defaultConnectionId().equals(selected)) proxy.disconnect();
                }
                case "connection.test" -> test(requiredConfig().profile(command.get("connectionId").getAsString()),
                        Authority.parse(command.get("target").getAsString(), -1));
                default -> throw new IllegalArgumentException("未知控制命令");
            }
            emit(Map.of("event", "response", "id", id, "ok", true, "status", status(), "data", data));
            publishStatus();
            return !action.equals("exit");
        } catch (Exception e) {
            // 配置解析器或 TLS 异常可能包含输入值，控制错误仅返回类别，避免泄露凭证。
            String message = e instanceof IllegalArgumentException || e instanceof IllegalStateException
                    ? "操作未执行，请检查配置字段、唯一性及运行状态" : "操作失败，请检查文件、网络及证书";
            emit(Map.of("event", "response", "id", id, "ok", false, "message", message, "errorType", e.getClass().getSimpleName()));
            return true;
        }
    }
    private KernelConfig requiredConfig() {
        if (config == null) throw new IllegalStateException("尚未设置连接配置");
        return config;
    }
    private void apply(KernelConfig next) throws Exception {
        if (proxy != null) proxy.apply(next);
        config = next;
    }
    private void start(JsonObject command) throws Exception {
        if (proxy != null) throw new IllegalStateException("代理已经运行，请先停止");
        if (command.has("config") || command.has("rules"))
            throw new IllegalArgumentException("请使用 configuration 提交完整 JSON 配置");
        KernelConfig next = config;
        if (command.has("configuration")) next = KernelConfig.parse(command.getAsJsonObject("configuration"), Path.of("."));
        if (next == null) throw new IllegalStateException("尚未设置连接配置");
        proxy = new LocalProxyServer(next).start(); config = next;
    }
    private static void test(KernelConfig.Profile profile, Authority target) throws Exception {
        var group = new io.netty.channel.nio.NioEventLoopGroup(1);
        var resolver = Transport.resolver();
        try (ProxySession session = profile.config().get("protocol", "http3").equals("http2")
                ? new Http2Session(group.next(), profile.config(), resolver) : new Http3Session(group.next(), profile.config(), resolver)) {
            var result = session.open(target);
            if (!result.await(profile.config().connectTimeoutMillis() * 3L)) { result.cancel(false); throw new IOException("连通性测试超时"); }
            if (!result.isSuccess()) throw new IOException("连通性测试失败", result.cause());
            result.getNow().close().sync();
        } finally { resolver.close(); group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly(); }
    }
    private Map<String, Object> status() {
        Map<String, Object> status = new LinkedHashMap<>();
        status.put("running", proxy != null);
        status.put("connection", proxy == null ? "idle" : proxy.connectionState());
        status.put("error", proxy == null ? "" : proxy.lastError());
        status.put("address", proxy == null ? "" : proxy.address().getHostString() + ":" + proxy.address().getPort());
        status.put("defaultConnectionId", config == null ? "" : config.defaultConnectionId());
        status.put("connections", config == null ? List.of() : config.connections().stream().map(p -> Map.of(
                "id", p.id(), "name", p.name(), "protocol", p.config().get("protocol", "http3"),
                "state", proxy != null && p.id().equals(config.defaultConnectionId()) ? proxy.connectionState() : "idle",
                "activeTunnels", proxy != null && p.id().equals(config.defaultConnectionId()) ? proxy.activeTunnels() : 0,
                "pendingTunnels", proxy != null && p.id().equals(config.defaultConnectionId()) ? proxy.pendingTunnels() : 0)).toList());
        return status;
    }
    private synchronized void publishStatus() {
        if (closed) return;
        var state = status(); String encoded = JSON.toJson(state);
        if (!encoded.equals(previous)) { previous = encoded; emit(Map.of("event", "status", "status", state)); }
    }
    private synchronized void emit(Object event) { output.println(JSON.toJson(event)); output.flush(); }
    private void stop() { if (proxy != null) { proxy.close(); proxy = null; } }
    @Override public synchronized void close() { closed = true; events.shutdownNow(); stop(); }
}
