package com.blacicada.control.web;

import com.blacicada.control.*;
import com.google.gson.*;
import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** 独立的本机管理监听，不与代理数据端口共用。 */
public final class ControlHttpServer implements AutoCloseable {
    private final KernelControl control;
    private final ControlApi api;
    private final HttpServer server;
    private final String token;
    private final Set<String> origins;
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
    private final Semaphore requests = new Semaphore(32), subscriptions = new Semaphore(16);
    private final AtomicBoolean closed = new AtomicBoolean();
    private final CountDownLatch stopped = new CountDownLatch(1);
    private static final Gson JSON = new Gson();
    private static final int MAX_BODY = 1_048_576;

    public ControlHttpServer(KernelControl control, int port, String token, Set<String> origins) throws IOException {
        if (token == null || token.length() < 32) throw new IllegalArgumentException("管理令牌至少需要 32 个字符");
        this.control = control; this.api = new ControlApi(control); this.token = token; this.origins = Set.copyOf(origins);
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 32);
        server.setExecutor(workers); server.createContext("/", this::handle);
    }
    public void start() { server.start(); }
    public int port() { return server.getAddress().getPort(); }
    public String url() { return "http://127.0.0.1:" + port(); }
    public void await() throws InterruptedException { stopped.await(); }
    private void handle(HttpExchange exchange) {
        String requestId = UUID.randomUUID().toString();
        boolean acquired = false;
        try {
            Headers headers = exchange.getResponseHeaders();
            headers.set("Cache-Control", "no-store"); headers.set("X-Content-Type-Options", "nosniff");
            String host = exchange.getRequestHeaders().getFirst("Host");
            if (!Set.of("127.0.0.1:" + port(), "localhost:" + port()).contains(host == null ? "" : host))
                throw new ControlException(403, "INVALID_HOST", "管理接口只接受本机地址");
            String origin = exchange.getRequestHeaders().getFirst("Origin");
            if (origin != null) {
                if (!origins.contains(origin) && !url().equals(origin)) throw new ControlException(403, "ORIGIN_DENIED", "未允许此页面访问管理接口");
                headers.set("Access-Control-Allow-Origin", origin); headers.set("Vary", "Origin");
                headers.set("Access-Control-Expose-Headers", "ETag");
            }
            if (exchange.getRequestMethod().equals("OPTIONS")) {
                if (origin == null) throw new ControlException(400, "INVALID_PREFLIGHT", "缺少页面来源");
                headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS");
                headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-Match, Last-Event-ID");
                exchange.sendResponseHeaders(204, -1); return;
            }
            String authorization = exchange.getRequestHeaders().getFirst("Authorization");
            if (authorization == null || !MessageDigest.isEqual(("Bearer " + token).getBytes(StandardCharsets.UTF_8), authorization.getBytes(StandardCharsets.UTF_8)))
                throw new ControlException(401, "UNAUTHORIZED", "管理令牌无效");
            String path = exchange.getRequestURI().getPath(), method = exchange.getRequestMethod();
            if (path.equals("/api/v1/events") && method.equals("GET")) { events(exchange); return; }
            if (!(acquired = requests.tryAcquire())) throw new ControlException(429, "CONTROL_BUSY", "管理请求过多，请稍后重试");
            JsonObject body = Set.of("POST", "PUT", "PATCH").contains(method) ? body(exchange) : new JsonObject();
            var response = api.dispatch(method, exchange.getRequestURI(), body,
                    exchange.getRequestHeaders().getFirst("If-Match"), requestId);
            if (response.body().containsKey("revision"))
                exchange.getResponseHeaders().set("ETag", "\"" + response.body().get("revision") + "\"");
            send(exchange, response.status(), response.body());
            if (response.shutdown()) Thread.ofPlatform().daemon().start(this::close);
        } catch (ControlException e) {
            error(exchange, e.status, requestId, e.code, control.redact(e.getMessage()), e.field);
        } catch (JsonParseException | IllegalArgumentException | IllegalStateException | NullPointerException e) {
            error(exchange, 400, requestId, "INVALID_REQUEST", "请求格式或参数无效", "");
        } catch (Exception e) {
            error(exchange, 500, requestId, "CONTROL_FAILED", "操作未完成，请检查网络、文件权限或证书", "");
        } finally { if (acquired) requests.release(); exchange.close(); }
    }
    private static JsonObject body(HttpExchange exchange) throws IOException {
        byte[] bytes = exchange.getRequestBody().readNBytes(MAX_BODY + 1);
        if (bytes.length > MAX_BODY) throw new ControlException(413, "BODY_TOO_LARGE", "请求内容超过大小限制");
        if (bytes.length == 0) return new JsonObject();
        String type = exchange.getRequestHeaders().getFirst("Content-Type");
        if (type == null || !type.split(";", 2)[0].trim().equalsIgnoreCase("application/json"))
            throw new ControlException(415, "JSON_REQUIRED", "请求内容必须为 JSON");
        return JsonParser.parseString(new String(bytes, StandardCharsets.UTF_8)).getAsJsonObject();
    }
    private static void send(HttpExchange exchange, int status, Object body) throws IOException {
        byte[] bytes = JSON.toJson(body).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        exchange.getResponseBody().write(bytes); exchange.getResponseBody().flush();
    }
    private static void error(HttpExchange exchange, int status, String requestId, String code, String message, String field) {
        try { send(exchange, status, Map.of("requestId", requestId, "error", Map.of("code", code, "message", message, "field", field))); }
        catch (IOException ignored) { }
    }
    private void events(HttpExchange exchange) throws Exception {
        if (!subscriptions.tryAcquire()) throw new ControlException(429, "TOO_MANY_SUBSCRIPTIONS", "事件订阅数量已满");
        try {
            long cursor;
            String previous = exchange.getRequestHeaders().getFirst("Last-Event-ID");
            cursor = previous == null ? control.events().cursor() : Long.parseLong(previous);
            if (cursor < 0) throw new ControlException(400, "INVALID_CURSOR", "事件游标无效");
            exchange.getResponseHeaders().set("Content-Type", "text/event-stream; charset=utf-8");
            exchange.sendResponseHeaders(200, 0);
            OutputStream output = exchange.getResponseBody();
            if (previous == null) writeEvent(output, cursor, "snapshot", control.status());
            while (!closed.get()) {
                var batch = control.events().await(cursor, 10000);
                if (batch.reset()) writeEvent(output, batch.cursor(), "snapshot", control.status());
                else if (batch.events().isEmpty()) { output.write(": 保持管理订阅\n\n".getBytes(StandardCharsets.UTF_8)); output.flush(); }
                else for (var event : batch.events()) writeEvent(output, event.id(), event.type(), event.data());
                cursor = batch.cursor();
            }
        } finally { subscriptions.release(); }
    }
    private static void writeEvent(OutputStream output, long id, String type, Object data) throws IOException {
        output.write(("id: " + id + "\nevent: " + type + "\ndata: " + JSON.toJson(data) + "\n\n").getBytes(StandardCharsets.UTF_8)); output.flush();
    }
    public static String newToken() {
        byte[] bytes = new byte[32]; new SecureRandom().nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
    public void writeEndpoint(Path file) throws IOException {
        Path path = file.toAbsolutePath(); Files.createDirectories(path.getParent());
        Path temp = Files.createTempFile(path.getParent(), ".control-", ".json");
        try {
            if (Files.getFileStore(temp).supportsFileAttributeView("posix")) Files.setPosixFilePermissions(temp, PosixFilePermissions.fromString("rw-------"));
            Files.writeString(temp, JSON.toJson(Map.of("url", url(), "token", token, "pid", ProcessHandle.current().pid(), "apiVersion", 1)) + "\n");
            Files.move(temp, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temp); }
    }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        try { control.close(); } finally { server.stop(0); workers.shutdownNow(); stopped.countDown(); }
    }
}
