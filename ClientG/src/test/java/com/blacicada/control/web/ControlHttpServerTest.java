package com.blacicada.control.web;

import com.blacicada.common.h3.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.control.*;
import com.blacicada.h2.Http2ProxyServer;
import com.google.gson.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.net.*;
import java.net.http.*;
import java.nio.file.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(30)
class ControlHttpServerTest {
    @TempDir Path directory;
    KernelControl control;
    ControlHttpServer web;
    HttpClient client;
    final String token = "management-test-token-at-least-32-characters";
    long revision;
    @BeforeEach void start() throws Exception {
        control = new KernelControl(directory.resolve("kernel.json"));
        web = new ControlHttpServer(control, 0, token, Set.of("http://localhost:3000")); web.start();
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();
    }
    @AfterEach void stop() { web.close(); client.close(); }
    HttpResponse<String> request(String method, String path, String body, String... headers) throws Exception {
        var builder = HttpRequest.newBuilder(URI.create(web.url() + "/api/v1" + path)).timeout(Duration.ofSeconds(5))
                .header("Authorization", "Bearer " + token).header("Content-Type", "application/json");
        for (int i = 0; i < headers.length; i += 2) builder.header(headers[i], headers[i + 1]);
        return client.send(builder.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body)).build(), HttpResponse.BodyHandlers.ofString());
    }
    JsonObject ok(String method, String path, String body, int expected) throws Exception {
        var response = request(method, path, body, "If-Match", "\"" + revision + "\"");
        assertEquals(expected, response.statusCode(), response.body());
        JsonObject json = JsonParser.parseString(response.body()).getAsJsonObject();
        if (json.has("revision")) revision = json.get("revision").getAsLong();
        return json;
    }
    String profile(String id, String protocol, int port) {
        return "{\"id\":\"" + id + "\",\"name\":\"测试连接\",\"config\":{\"protocol\":\"" + protocol
                + "\",\"server.host\":\"127.0.0.1\",\"server.port\":" + port + ",\"password\":\"test-secret\",\"connectTimeoutMillis\":1000}}";
    }
    String resource(String name) throws Exception { return Path.of(getClass().getResource("/tls/" + name).toURI()).toString(); }
    void addProfile(String id, String protocol, int port, boolean certificate) throws Exception {
        JsonObject p = JsonParser.parseString(profile(id, protocol, port)).getAsJsonObject();
        if (certificate) { p.getAsJsonObject("config").addProperty("tls.ca", resource("localhost.crt")); p.getAsJsonObject("config").addProperty("tls.serverName", "localhost"); }
        ok("POST", "/profiles", p.toString(), 201);
    }
    @Test void authenticatesAndRejectsUntrustedOriginsAndMalformedBodies() throws Exception {
        var anonymous = client.send(HttpRequest.newBuilder(URI.create(web.url() + "/api/v1/health")).build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(401, anonymous.statusCode());
        assertEquals(403, request("GET", "/health", null, "Origin", "https://untrusted.invalid").statusCode());
        assertEquals(204, request("OPTIONS", "/config", null, "Origin", "http://localhost:3000").statusCode());
        assertEquals(400, request("PUT", "/config", "[]", "If-Match", "0").statusCode());
        assertEquals(428, request("PATCH", "/settings", "{}").statusCode());
        assertEquals(413, request("PUT", "/config", "x".repeat(1_048_577), "If-Match", "0").statusCode());
        ok("POST", "/proxy/start", null, 409);
        ok("GET", "/health", null, 200);
    }
    @Test void revisionsPasswordsUniquenessPersistenceAndEmptyConfiguration() throws Exception {
        addProfile("a", "http2", 4433, false);
        long first = revision;
        var view = ok("GET", "/config", null, 200);
        assertFalse(view.toString().contains("test-secret"));
        assertTrue(view.getAsJsonObject("data").getAsJsonArray("connections").get(0).getAsJsonObject().get("hasPassword").getAsBoolean());
        ok("PATCH", "/profiles/a", "{\"name\":\"重命名\"}", 200);
        assertEquals(409, request("PATCH", "/profiles/a", "{}", "If-Match", "" + first).statusCode());
        ok("POST", "/profiles", profile("duplicate", "http2", 4433), 409);
        ok("POST", "/config/save", null, 200);
        var loaded = KernelConfig.load(directory.resolve("kernel.json"));
        assertEquals("test-secret", loaded.profile("a").config().required("password"));
        assertEquals("重命名", loaded.profile("a").name());
        assertFalse(ok("GET", "/status", null, 200).get("dirty").getAsBoolean());
        ok("DELETE", "/profiles/a", null, 200);
        assertEquals(0, ok("GET", "/profiles", null, 200).getAsJsonArray("data").size());
        ok("POST", "/config/save", null, 200);
        assertTrue(KernelConfig.load(directory.resolve("kernel.json")).connections().isEmpty());
        web.writeEndpoint(directory.resolve("control.json"));
        assertTrue(Files.readString(directory.resolve("control.json")).contains(token));
        assertEquals("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(Files.getPosixFilePermissions(directory.resolve("control.json"))));
    }
    @Test void listenerChangeRestartsImmediatelyAndFailureRollsBack() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"\"}", 200);
        String before = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").get("address").getAsString();
        try (Socket old = new Socket("127.0.0.1", Integer.parseInt(before.substring(before.lastIndexOf(':') + 1)))) {
            old.setSoTimeout(3000);
            int newPort;
            try (var free = new ServerSocket(0)) { newPort = free.getLocalPort(); }
            var changed = ok("PATCH", "/settings", "{\"port\":" + newPort + "}", 200);
            assertFalse(changed.get("requiresProxyRestart").getAsBoolean());
            assertEquals(-1, old.getInputStream().read());
            String address = ok("GET", "/status", null, 200).getAsJsonObject("data").get("address").getAsString();
            assertEquals("127.0.0.1:" + newPort, address);
            long unchanged = revision;
            try (var occupied = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))) { ok("PATCH", "/settings", "{\"port\":" + occupied.getLocalPort() + "}", 409); }
            var restored = ok("GET", "/status", null, 200);
            assertEquals(unchanged, revision); assertEquals(address, restored.getAsJsonObject("data").get("address").getAsString());
            assertTrue(restored.getAsJsonObject("data").get("running").getAsBoolean());
        }
        ok("POST", "/proxy/stop", null, 200);
        ok("GET", "/health", null, 200);
    }
    static Socket tunnel(int proxyPort, int targetPort) throws Exception {
        Socket socket = new Socket("127.0.0.1", proxyPort); socket.setSoTimeout(4000);
        socket.getOutputStream().write(("CONNECT 127.0.0.1:" + targetPort + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes());
        StringBuilder header = new StringBuilder(); int value;
        while ((value = socket.getInputStream().read()) >= 0) { header.append((char) value); if (header.toString().endsWith("\r\n\r\n")) break; }
        assertTrue(header.toString().startsWith("HTTP/1.1 200"), header.toString()); return socket;
    }
    static void echo(Socket socket) throws Exception { socket.getOutputStream().write(42); assertEquals(42, socket.getInputStream().read()); }
    @Test void hotRulesAndNamesPreserveTunnelsButCredentialChangesCloseThem() throws Exception {
        Properties values = new Properties(); values.setProperty("port", "0"); values.setProperty("bind", "127.0.0.1");
        values.setProperty("password", "test-secret"); values.setProperty("tls.cert", resource("localhost.crt")); values.setProperty("tls.key", resource("localhost.key"));
        try (var server = new Http2ProxyServer(new ProxyConfig(values, directory)).start();
             var origin = new ServerSocket(0); var workers = Executors.newVirtualThreadPerTaskExecutor()) {
            workers.submit(() -> { while (!origin.isClosed()) try {
                Socket s = origin.accept(); workers.submit(() -> { try (s) { s.getInputStream().transferTo(s.getOutputStream()); } catch (IOException ignored) { } });
            } catch (IOException e) { break; } });
            try {
                addProfile("a", "http2", server.address().getPort(), true);
                ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"\"}", 200);
                String address = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").get("address").getAsString();
                int port = Integer.parseInt(address.substring(address.lastIndexOf(':') + 1));
                try (Socket active = tunnel(port, origin.getLocalPort())) {
                    echo(active); ok("PATCH", "/profiles/a", "{\"name\":\"新名字\"}", 200); echo(active);
                    // 候选配置合法但 TLS 初始化失败时，不应提交版本或中断旧会话。
                    Path brokenCa = directory.resolve("broken-ca.pem"); Files.writeString(brokenCa, "无效的证书内容");
                    JsonObject invalidPatch = new JsonObject(), invalidValues = new JsonObject();
                    invalidValues.addProperty("tls.ca", brokenCa.toString()); invalidPatch.add("config", invalidValues);
                    long previousRevision = revision;
                    ok("PATCH", "/profiles/a", invalidPatch.toString(), 400);
                    var unchanged = ok("GET", "/config", null, 200);
                    assertFalse(unchanged.toString().contains("broken-ca.pem"));
                    assertEquals(previousRevision, revision); echo(active);
                    ok("PUT", "/routing/direct-rules", "{\"rules\":\"127.0.0.0/8\"}", 200); echo(active);
                    try (Socket direct = tunnel(port, origin.getLocalPort())) {
                        echo(direct);
                        ok("PATCH", "/profiles/a", "{\"config\":{\"password\":\"changed-secret\"}}", 200);
                        assertEquals(-1, active.getInputStream().read()); echo(direct);
                    }
                }
            } finally { ok("POST", "/proxy/stop", null, 200); origin.close(); workers.shutdownNow(); }
        }
    }
    @Test void asynchronousDiagnosticsCanBeCancelledWithoutBlockingControl() throws Exception {
        try (var blackhole = new ServerSocket(0)) {
            addProfile("a", "http2", blackhole.getLocalPort(), false);
            var accepted = ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 202).getAsJsonObject("data");
            String id = accepted.get("id").getAsString();
            try (Socket tcp = blackhole.accept()) {
                ok("GET", "/status", null, 200);
                assertEquals("cancelled", ok("DELETE", "/operations/" + id, null, 200).getAsJsonObject("data").get("state").getAsString());
            }
            assertFalse(ok("GET", "/status", null, 200).getAsJsonObject("data").get("running").getAsBoolean());
        }
    }
    @Test void diagnosticTcpFailureAndRoutingResultAreObservable() throws Exception {
        int closedPort; try (var port = new ServerSocket(0)) { closedPort = port.getLocalPort(); }
        addProfile("a", "http2", closedPort, false);
        String id = ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 202).getAsJsonObject("data").get("id").getAsString();
        JsonObject job = awaitJob(id);
        assertEquals("failed", job.get("state").getAsString());
        assertEquals("TCP_CONNECT_FAILED", job.getAsJsonObject("result").get("code").getAsString());
        ok("PUT", "/routing/direct-rules", "{\"rules\":\"127.0.0.0/8\"}", 200);
        String route = ok("POST", "/routing/resolve", "{\"target\":\"127.0.0.1:80\"}", 202).getAsJsonObject("data").get("id").getAsString();
        assertEquals("direct", awaitJob(route).getAsJsonObject("result").get("action").getAsString());
    }
    JsonObject awaitJob(String id) throws Exception {
        for (int i = 0; i < 150; i++) {
            JsonObject job = ok("GET", "/operations/" + id, null, 200).getAsJsonObject("data");
            if (Set.of("failed", "succeeded", "cancelled").contains(job.get("state").getAsString())) return job;
            Thread.sleep(20);
        }
        throw new AssertionError("诊断任务未结束");
    }
    @Test void concurrentWritersCannotOverwriteTheSameRevision() throws Exception {
        addProfile("a", "http2", 4433, false);
        long sameVersion = revision;
        try (var workers = Executors.newVirtualThreadPerTaskExecutor()) {
            var one = workers.submit(() -> request("PATCH", "/profiles/a", "{\"name\":\"页面一\"}", "If-Match", "" + sameVersion));
            var two = workers.submit(() -> request("PATCH", "/profiles/a", "{\"name\":\"页面二\"}", "If-Match", "" + sameVersion));
            var codes = new ArrayList<>(List.of(one.get().statusCode(), two.get().statusCode()));
            Collections.sort(codes); assertEquals(List.of(200, 409), codes);
        }
    }
    @Test void diagnosticsLimitAndCancellationReleaseWorkSlots() throws Exception {
        try (var blackhole = new ServerSocket(0)) {
            addProfile("a", "http2", blackhole.getLocalPort(), false);
            ok("PATCH", "/profiles/a", "{\"config\":{\"connectTimeoutMillis\":10000}}", 200);
            List<String> ids = new ArrayList<>();
            for (int i = 0; i < 4; i++) ids.add(ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 202)
                    .getAsJsonObject("data").get("id").getAsString());
            ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 429);
            for (String id : ids) ok("DELETE", "/operations/" + id, null, 200);
            HttpResponse<String> retry = null;
            for (int i = 0; i < 100; i++) {
                retry = request("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}");
                if (retry.statusCode() == 202) break;
                assertEquals(429, retry.statusCode()); Thread.sleep(20);
            }
            assertNotNull(retry); assertEquals(202, retry.statusCode());
            String next = JsonParser.parseString(retry.body()).getAsJsonObject().getAsJsonObject("data").get("id").getAsString();
            ok("DELETE", "/operations/" + next, null, 200);
        }
    }
    @Test void logsFilterExactLevelsAndKeepPaginationAcrossSkippedRecords() throws Exception {
        for (String level : List.of("INFO", "WARN", "ERROR", "DEBUG", "WARN")) {
            control.logs().append(org.apache.logging.log4j.core.impl.Log4jLogEvent.newBuilder()
                    .setLoggerName("日志筛选测试").setLevel(org.apache.logging.log4j.Level.valueOf(level))
                    .setMessage(new org.apache.logging.log4j.message.SimpleMessage("测试消息：" + level)).build());
        }
        JsonObject first = ok("GET", "/logs?levels=warn&limit=1", null, 200).getAsJsonObject("data");
        assertEquals(1, first.getAsJsonArray("items").size());
        assertEquals("WARN", first.getAsJsonArray("items").get(0).getAsJsonObject().get("level").getAsString());
        long cursor = first.get("cursor").getAsLong();
        JsonObject second = ok("GET", "/logs?levels=WARN&limit=1&after=" + cursor, null, 200).getAsJsonObject("data");
        assertEquals(1, second.getAsJsonArray("items").size());
        assertTrue(second.get("cursor").getAsLong() > cursor);
        assertEquals("WARN", second.getAsJsonArray("items").get(0).getAsJsonObject().get("level").getAsString());
        var both = ok("GET", "/logs?levels=ERROR,WARN", null, 200).getAsJsonObject("data").getAsJsonArray("items");
        assertEquals(3, both.size());
        for (var entry : both) assertTrue(Set.of("WARN", "ERROR").contains(entry.getAsJsonObject().get("level").getAsString()));
        var empty = ok("GET", "/logs?levels=FATAL", null, 200).getAsJsonObject("data");
        assertTrue(empty.getAsJsonArray("items").isEmpty());
        assertEquals(empty.get("latestCursor"), empty.get("cursor"));
        assertEquals(5, ok("GET", "/logs", null, 200).getAsJsonObject("data").getAsJsonArray("items").size());
        for (String invalid : List.of("ALL", "warn,unknown", "", "WARN,")) {
            var response = ok("GET", "/logs?levels=" + invalid, null, 400);
            assertEquals("INVALID_LOG_LEVEL", response.getAsJsonObject("error").get("code").getAsString());
        }
    }
    @Test void rejectsRemovedStandaloneAndPipeModes() {
        for (String[] args : List.of(new String[]{"--ui"}, new String[]{"kernel.json"}, new String[0])) {
            var error = assertThrows(IllegalArgumentException.class, () -> com.blacicada.ClientApplication.main(args));
            assertTrue(error.getMessage().contains("--web"));
        }
    }
    @Test void eventDisconnectDoesNotStopProxyAndLogsAreRedactedAndPaged() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0}", 200); ok("POST", "/proxy/start", null, 200);
        var response = client.send(HttpRequest.newBuilder(URI.create(web.url() + "/api/v1/events"))
                .header("Authorization", "Bearer " + token).build(), HttpResponse.BodyHandlers.ofInputStream());
        assertEquals(200, response.statusCode());
        try (var reader = new BufferedReader(new InputStreamReader(response.body()))) {
            assertTrue(reader.readLine().startsWith("id:")); assertEquals("event: snapshot", reader.readLine());
            assertTrue(reader.readLine().contains("\"running\":true"));
        }
        assertTrue(ok("GET", "/status", null, 200).getAsJsonObject("data").get("running").getAsBoolean());
        for (int i = 0; i < 3; i++) org.apache.logging.log4j.LogManager.getLogger(getClass()).warn("测试日志 test-secret {}", i);
        JsonObject logs = null;
        // Log4j 异步投递日志，等待记录进入管理日志缓冲后再检查分页。
        for (int i = 0; i < 100; i++) {
            logs = ok("GET", "/logs?limit=1", null, 200).getAsJsonObject("data");
            if (logs.get("latestCursor").getAsLong() >= 3) break;
            Thread.sleep(20);
        }
        assertNotNull(logs);
        assertFalse(logs.toString().contains("test-secret")); assertEquals(1, logs.getAsJsonArray("items").size());
        long after = logs.get("cursor").getAsLong();
        var next = ok("GET", "/logs?limit=1&after=" + after, null, 200).getAsJsonObject("data");
        assertTrue(next.get("cursor").getAsLong() > after);
    }
}
