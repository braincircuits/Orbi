package com.blacicada.control.web;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.control.*;
import com.blacicada.h2.Http2ProxyServer;
import com.google.gson.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

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
    @TempDir
    Path directory;
    KernelControl control;
    ControlHttpServer web;
    HttpClient client;
    final String token = "management-test-token-at-least-32-characters";
    long revision;

    @BeforeEach
    void start() throws Exception {
        control = new KernelControl(directory.resolve("kernel.db"));
        web = new ControlHttpServer(control, 0, token, Set.of("http://localhost:3000"));
        web.start();
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build();
    }

    @AfterEach
    void stop() {
        web.close();
        client.close();
    }

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

    @Test
    void cancelledTunAuthorizationCannotInstallRoutesLater() throws Exception {
        Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        ok("POST", "/tun/request", "{\"engine\":\"outline\"}", 409);
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        ok("POST", "/proxy/start", null, 200);
        String ticket = ok("POST", "/tun/request", "{\"engine\":\"outline\"}", 200).getAsJsonObject("data").get("ticket").getAsString();
        ok("POST", "/tun/request", "{\"engine\":\"outline\"}", 409);
        ok("POST", "/proxy/restart", null, 409);
        ok("POST", "/tun/prepare", "{\"interface\":\"lo0\",\"ticket\":\"" + ticket + "\"}", 400);
        ok("POST", "/tun/stop", null, 200);
        ok("POST", "/tun/prepare", "{\"interface\":\"en0\",\"ticket\":\"" + ticket + "\"}", 409);
        ok("POST", "/tun/heartbeat", "{\"session\":\"" + ticket + "\",\"ready\":true}", 409);
        var status = ok("GET", "/status", null, 200).getAsJsonObject("data");
        assertTrue(status.get("running").getAsBoolean());
        assertEquals("off", status.getAsJsonObject("tun").get("state").getAsString());
        String next = ok("POST", "/tun/request", "{\"engine\":\"outline\"}", 200).getAsJsonObject("data").get("ticket").getAsString();
        assertNotEquals(ticket, next);
        ok("POST", "/tun/finish", "{\"session\":\"" + ticket + "\",\"error\":\"迟到的退出\"}", 200);
        assertEquals("authorizing", ok("GET", "/status", null, 200).getAsJsonObject("data").getAsJsonObject("tun").get("state").getAsString());
        ok("POST", "/proxy/stop", null, 200);
        ok("POST", "/tun/prepare", "{\"interface\":\"en0\",\"ticket\":\"" + next + "\"}", 409);
    }

    @ParameterizedTest
    @ValueSource(strings = {"outline", "tun2socks"})
    void tunLifecycleRestoresUnboundKernelAfterHelperCleanup(String engine) throws Exception {
        Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        var network = Collections.list(NetworkInterface.getNetworkInterfaces()).stream().filter(n -> {
            try {
                return n.getName().startsWith("en") && n.isUp() && !n.isLoopback() && !n.isPointToPoint();
            } catch (SocketException e) {
                return false;
            }
        }).findFirst();
        Assumptions.assumeTrue(network.isPresent());
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        ok("POST", "/proxy/start", null, 200);
        String ticket = ok("POST", "/tun/request", "{\"engine\":\"" + engine + "\"}", 200).getAsJsonObject("data").get("ticket").getAsString();
        var prepared = ok("POST", "/tun/prepare", "{\"interface\":\"" + network.get().getName() + "\",\"ticket\":\"" + ticket + "\"}", 200).getAsJsonObject("data");
        assertEquals(ticket, prepared.get("session").getAsString());
        assertEquals(engine, prepared.get("engine").getAsString());
        String heartbeat = "{\"session\":\"" + ticket + "\",\"ready\":true}";
        assertFalse(ok("POST", "/tun/heartbeat", heartbeat, 200).getAsJsonObject("data").get("stop").getAsBoolean());
        var tun = ok("GET", "/status", null, 200).getAsJsonObject("data").getAsJsonObject("tun");
        assertEquals("running", tun.get("state").getAsString());
        assertEquals(engine, tun.get("engine").getAsString());
        ok("POST", "/tun/request", "{\"engine\":\"tun2socks\"}", 409);
        assertEquals(network.get().getIndex(), tun.get("interfaceIndex").getAsInt());
        ok("PATCH", "/settings", "{\"port\":12345}", 409);
        ok("POST", "/tun/stop", null, 200);
        assertTrue(ok("POST", "/tun/heartbeat", heartbeat, 200).getAsJsonObject("data").get("stop").getAsBoolean());
        ok("POST", "/tun/finish", "{\"session\":\"" + ticket + "\",\"error\":\"\"}", 200);
        var status = ok("GET", "/status", null, 200).getAsJsonObject("data");
        assertTrue(status.get("running").getAsBoolean());
        assertEquals("off", status.getAsJsonObject("tun").get("state").getAsString());
        assertEquals(0, status.getAsJsonObject("tun").get("interfaceIndex").getAsInt());
    }

    @Test
    void tunEngineMustBeExplicitAndKnown() throws Exception {
        for (String body : Arrays.asList(null, "{}", "{\"engine\":\"unknown\"}")) {
            ok("POST", "/tun/request", body, 400);
            assertEquals("off", ok("GET", "/status", null, 200).getAsJsonObject("data").getAsJsonObject("tun").get("state").getAsString());
        }
    }

    @Test
    void trafficWindowsAreDefinedByKernelAndExcludeUnfinishedHours() throws Exception {
        var minutes = ok("GET", "/traffic/trend", null, 200).getAsJsonObject("data");
        assertEquals(1440, minutes.getAsJsonArray("buckets").size());
        assertEquals("minute", minutes.get("interval").getAsString());
        assertEquals(java.time.ZoneId.systemDefault().getId(), minutes.get("zoneId").getAsString());
        var hours = ok("GET", "/traffic/history", null, 200).getAsJsonObject("data");
        assertEquals("hour", hours.get("interval").getAsString());
        assertTrue(hours.getAsJsonArray("buckets").size() >= 28 * 24 - 1);
        assertTrue(hours.getAsJsonArray("buckets").size() <= 31 * 24 + 1);
        assertTrue(hours.get("to").getAsLong() <= System.currentTimeMillis());
    }

    String profile(String id, String protocol, int port) {
        return "{\"id\":\"" + id + "\",\"name\":\"测试连接\",\"config\":{\"protocol\":\"" + protocol
                + "\",\"server.host\":\"127.0.0.1\",\"server.port\":" + port + ",\"password\":\"test-secret\",\"connectTimeoutMillis\":1000}}";
    }

    String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }

    void addProfile(String id, String protocol, int port, boolean certificate) throws Exception {
        JsonObject p = JsonParser.parseString(profile(id, protocol, port)).getAsJsonObject();
        if (certificate) {
            p.getAsJsonObject("config").addProperty("tls.ca", resource("localhost.crt"));
            p.getAsJsonObject("config").addProperty("tls.serverName", "localhost");
        }
        ok("POST", "/profiles", p.toString(), 201);
    }

    KernelConfig persisted() throws Exception {
        // 通过独立只读 SQL 查询验证提交结果，不另开一个持有进程锁的内核。
        try (var db = java.sql.DriverManager.getConnection("jdbc:sqlite:" + directory.resolve("kernel.db"))) {
            JsonObject root = control.configuration();
            try (var query = db.createStatement(); var rows = query.executeQuery("SELECT revision FROM metadata")) {
                assertTrue(rows.next());
                assertEquals(revision, rows.getLong(1));
            }
            try (var query = db.createStatement(); var rows = query.executeQuery("SELECT profile_id,value FROM profile_settings WHERE key='password'")) {
                while (rows.next()) for (var item : root.getAsJsonArray("connections"))
                    if (item.getAsJsonObject().get("id").getAsString().equals(rows.getString(1)))
                        item.getAsJsonObject().getAsJsonObject("config").addProperty("password", rows.getString(2));
            }
            try (var query = db.createStatement(); var rows = query.executeQuery("SELECT mode,direct_rules FROM routing")) {
                assertTrue(rows.next());
                root.getAsJsonObject("local").addProperty("routingMode", rows.getString(1));
                root.getAsJsonObject("local").addProperty("routesInline", rows.getString(2));
            }
            return KernelConfig.parse(root, directory);
        }
    }

    @Test
    void overviewRequiresRunningServiceAndModesAreRevisionedAndPersistent() throws Exception {
        ok("POST", "/overview/websites", null, 409);
        ok("POST", "/overview/exit-ip", null, 409);
        ok("POST", "/overview/latency", null, 409);
        ok("PUT", "/routing/mode", "{\"mode\":\"invalid\"}", 400);
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        var started = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data");
        assertEquals("direct", started.get("routingMode").getAsString());
        assertEquals("unused", started.get("connection").getAsString());
        long generation = started.get("networkGeneration").getAsLong();
        ok("POST", "/overview/latency", null, 409);
        var resolved = ok("POST", "/routing/resolve", "{\"target\":\"example.com:443\"}", 202);
        String id = resolved.getAsJsonObject("data").get("id").getAsString();
        for (int i = 0; i < 100; i++) {
            var task = ok("GET", "/operations/" + id, null, 200).getAsJsonObject("data");
            if (task.get("state").getAsString().equals("succeeded")) {
                assertEquals("global_mode", task.getAsJsonObject("result").get("matchedBy").getAsString());
                break;
            }
            Thread.sleep(10);
        }
        assertEquals("succeeded", ok("GET", "/operations/" + id, null, 200).getAsJsonObject("data").get("state").getAsString());
        assertEquals("direct", persisted().routingMode());
        var stopped = ok("POST", "/proxy/stop", null, 200).getAsJsonObject("data");
        assertTrue(stopped.get("networkGeneration").getAsLong() > generation);
    }

    @Test
    void authenticatesAndRejectsUntrustedOriginsAndMalformedBodies() throws Exception {
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

    @Test
    void trafficApiRetainsStoppedHistoryAndResetsOnStart() throws Exception {
        var empty = ok("GET", "/traffic", null, 200).getAsJsonObject("data");
        assertEquals("", empty.get("sessionId").getAsString());
        assertFalse(empty.has("history"));
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        var started = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").getAsJsonObject("traffic");
        assertFalse(started.has("history"));
        Thread.sleep(1100);
        var live = ok("GET", "/traffic", null, 200).getAsJsonObject("data");
        assertTrue(live.get("sampledAt").getAsLong() > live.get("startedAt").getAsLong());
        assertFalse(((Map<?, ?>) control.snapshot().get("traffic")).containsKey("history"));
        var stopped = ok("POST", "/proxy/stop", null, 200).getAsJsonObject("data").getAsJsonObject("traffic");
        assertEquals(started.get("sessionId"), stopped.get("sessionId"));
        assertEquals(0, stopped.get("sendBytesPerSecond").getAsDouble());
        var next = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").getAsJsonObject("traffic");
        assertNotEquals(started.get("sessionId"), next.get("sessionId"));
        assertEquals(0, next.get("sentBytes").getAsLong());
    }

    @Test
    void historyEndpointsMergeMinutesAndValidateAccessQueries() throws Exception {
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        ok("POST", "/proxy/start", null, 200);
        ok("POST", "/proxy/stop", null, 200);
        ok("POST", "/proxy/start", null, 200);
        ok("POST", "/proxy/stop", null, 200);
        var page = ok("GET", "/traffic/trend", null, 200).getAsJsonObject("data");
        assertEquals(1, page.get("recordCount").getAsInt());
        assertTrue(ok("GET", "/access-records?target=example.com", null, 200).getAsJsonObject("data").getAsJsonArray("items").isEmpty());
        ok("GET", "/access-records?limit=0", null, 400);
        ok("GET", "/access-records?beforeValue=invalid", null, 400);
        ok("GET", "/access-records?failedOnly=true", null, 200);
        ok("GET", "/access-records?order=unknown", null, 400);
        ok("GET", "/access-records?ascending=invalid", null, 400);
        for (String order : List.of("host", "count", "recent", "failure")) {
            for (String ascending : List.of("true", "false"))
                ok("GET", "/access-records?order=" + order + "&ascending=" + ascending, null, 200);
        }
    }

    @Test
    void tunnelApiAndEventsIncludeDirectConnectionsAndClearOnStop() throws Exception {
        assertTrue(ok("GET", "/tunnels", null, 200).getAsJsonArray("data").isEmpty());
        assertTrue(ok("GET", "/info", null, 200).toString().contains("\"tunnels\""));
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"127.0.0.1\"}", 200);
        String address = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").get("address").getAsString();
        try (var origin = new ServerSocket(0);
             Socket direct = tunnel(Integer.parseInt(address.substring(address.lastIndexOf(':') + 1)), origin.getLocalPort());
             Socket target = origin.accept()) {
            var item = ok("GET", "/tunnels", null, 200).getAsJsonArray("data").get(0).getAsJsonObject();
            assertEquals("direct", item.get("route").getAsString());
            assertEquals("active", item.get("state").getAsString());
            assertEquals("127.0.0.1:" + origin.getLocalPort(), item.get("target").getAsString());
            assertFalse(item.toString().contains("test-secret"));
            var response = client.send(HttpRequest.newBuilder(URI.create(web.url() + "/api/v1/events"))
                    .header("Authorization", "Bearer " + token).build(), HttpResponse.BodyHandlers.ofInputStream());
            try (var reader = new BufferedReader(new InputStreamReader(response.body()))) {
                reader.readLine();
                assertEquals("event: snapshot", reader.readLine());
                var snapshot = JsonParser.parseString(reader.readLine().substring(6)).getAsJsonObject();
                assertEquals(1, snapshot.getAsJsonArray("tunnels").size());
            }
            long cursor = control.events().cursor();
            ok("POST", "/proxy/stop", null, 200);
            assertTrue(ok("GET", "/tunnels", null, 200).getAsJsonArray("data").isEmpty());
            assertTrue(control.events().await(cursor, 0).events().stream().anyMatch(event ->
                    event.type().equals("status") && ((java.util.Map<?, ?>) event.data()).get("tunnels").equals(List.of())));
        }
    }

    @Test
    void revisionsPasswordsUniquenessPersistenceAndEmptyConfiguration() throws Exception {
        addProfile("a", "http2", 4433, false);
        long first = revision;
        var view = ok("GET", "/config", null, 200);
        assertFalse(view.toString().contains("test-secret"));
        assertTrue(view.getAsJsonObject("data").getAsJsonArray("connections").get(0).getAsJsonObject().get("hasPassword").getAsBoolean());
        ok("PATCH", "/profiles/a", "{\"name\":\"重命名\"}", 200);
        assertEquals(409, request("PATCH", "/profiles/a", "{}", "If-Match", "" + first).statusCode());
        ok("POST", "/profiles", profile("duplicate", "http2", 4433), 409);
        var loaded = persisted();
        assertEquals("test-secret", loaded.profile("a").config().required("password"));
        assertEquals("重命名", loaded.profile("a").name());
        assertFalse(ok("GET", "/status", null, 200).has("dirty"));
        ok("DELETE", "/profiles/a", null, 200);
        assertEquals(0, ok("GET", "/profiles", null, 200).getAsJsonArray("data").size());
        assertTrue(persisted().connections().isEmpty());
        web.writeEndpoint(directory.resolve("control.json"));
        assertTrue(Files.readString(directory.resolve("control.json")).contains(token));
        assertEquals("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(Files.getPosixFilePermissions(directory.resolve("control.json"))));
    }

    @Test
    void listenerChangeRestartsImmediatelyAndFailureRollsBack() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"\"}", 200);
        String before = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").get("address").getAsString();
        try (Socket old = new Socket("127.0.0.1", Integer.parseInt(before.substring(before.lastIndexOf(':') + 1)))) {
            old.setSoTimeout(3000);
            int newPort;
            try (var free = new ServerSocket(0)) {
                newPort = free.getLocalPort();
            }
            var changed = ok("PATCH", "/settings", "{\"port\":" + newPort + "}", 200);
            assertFalse(changed.get("requiresProxyRestart").getAsBoolean());
            assertEquals(-1, old.getInputStream().read());
            String address = ok("GET", "/status", null, 200).getAsJsonObject("data").get("address").getAsString();
            assertEquals("127.0.0.1:" + newPort, address);
            long unchanged = revision;
            try (var occupied = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))) {
                ok("PATCH", "/settings", "{\"port\":" + occupied.getLocalPort() + "}", 409);
            }
            var restored = ok("GET", "/status", null, 200);
            assertEquals(unchanged, revision);
            assertEquals(address, restored.getAsJsonObject("data").get("address").getAsString());
            assertTrue(restored.getAsJsonObject("data").get("running").getAsBoolean());
        }
        ok("POST", "/proxy/stop", null, 200);
        ok("GET", "/health", null, 200);
    }

    static Socket tunnel(int proxyPort, int targetPort) throws Exception {
        Socket socket = new Socket("127.0.0.1", proxyPort);
        socket.setSoTimeout(4000);
        socket.getOutputStream().write(("CONNECT 127.0.0.1:" + targetPort + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes());
        StringBuilder header = new StringBuilder();
        int value;
        while ((value = socket.getInputStream().read()) >= 0) {
            header.append((char) value);
            if (header.toString().endsWith("\r\n\r\n")) break;
        }
        assertTrue(header.toString().startsWith("HTTP/1.1 200"), header.toString());
        return socket;
    }

    static void echo(Socket socket) throws Exception {
        socket.getOutputStream().write(42);
        assertEquals(42, socket.getInputStream().read());
    }

    @Test
    void hotRulesCloseAffectedTunnelsAndPreserveDirectTrafficOnCredentialChanges() throws Exception {
        Properties values = new Properties();
        values.setProperty("port", "0");
        values.setProperty("bind", "127.0.0.1");
        values.setProperty("password", "test-secret");
        values.setProperty("tls.cert", resource("localhost.crt"));
        values.setProperty("tls.key", resource("localhost.key"));
        try (var server = new Http2ProxyServer(new ProxyConfig(values, directory)).start();
             var origin = new ServerSocket(0); var workers = Executors.newVirtualThreadPerTaskExecutor()) {
            workers.submit(() -> {
                while (!origin.isClosed()) try {
                    Socket s = origin.accept();
                    workers.submit(() -> {
                        try (s) {
                            s.getInputStream().transferTo(s.getOutputStream());
                        } catch (IOException ignored) {
                        }
                    });
                } catch (IOException e) {
                    break;
                }
            });
            try {
                addProfile("a", "http2", server.address().getPort(), true);
                ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"\"}", 200);
                String address = ok("POST", "/proxy/start", null, 200).getAsJsonObject("data").get("address").getAsString();
                int port = Integer.parseInt(address.substring(address.lastIndexOf(':') + 1));
                try (Socket active = tunnel(port, origin.getLocalPort())) {
                    echo(active);
                    ok("PATCH", "/profiles/a", "{\"name\":\"新名字\"}", 200);
                    echo(active);
                    // 候选配置合法但 TLS 初始化失败时，不应提交版本或中断旧会话。
                    Path brokenCa = directory.resolve("broken-ca.pem");
                    Files.writeString(brokenCa, "无效的证书内容");
                    JsonObject invalidPatch = new JsonObject(), invalidValues = new JsonObject();
                    invalidValues.addProperty("tls.ca", brokenCa.toString());
                    invalidPatch.add("config", invalidValues);
                    long previousRevision = revision;
                    ok("PATCH", "/profiles/a", invalidPatch.toString(), 400);
                    var unchanged = ok("GET", "/config", null, 200);
                    assertFalse(unchanged.toString().contains("broken-ca.pem"));
                    assertEquals(previousRevision, revision);
                    echo(active);
                    ok("PUT", "/routing/direct-rules", "{\"rules\":\"10.0.0.0/8\"}", 200);
                    echo(active);
                    ok("PUT", "/routing/direct-rules", "{\"rules\":\"127.0.0.0/8\"}", 200);
                    assertEquals(-1, active.getInputStream().read());
                    try (Socket direct = tunnel(port, origin.getLocalPort())) {
                        echo(direct);
                        ok("PUT", "/routing/targets", "{\"target\":\"127.0.0.1:" + origin.getLocalPort() + "\",\"route\":\"proxy\"}", 200);
                        assertEquals(-1, direct.getInputStream().read());
                        try (Socket forcedProxy = tunnel(port, origin.getLocalPort())) {
                            echo(forcedProxy);
                            assertEquals("proxy", ok("GET", "/tunnels", null, 200).getAsJsonArray("data").get(0).getAsJsonObject().get("route").getAsString());
                            ok("PUT", "/routing/targets", "{\"target\":\"127.0.0.1:" + origin.getLocalPort() + "\",\"route\":\"auto\"}", 200);
                            assertEquals(-1, forcedProxy.getInputStream().read());
                        }
                    }
                    try (Socket direct = tunnel(port, origin.getLocalPort())) {
                        ok("PATCH", "/profiles/a", "{\"config\":{\"password\":\"changed-secret\"}}", 200);
                        echo(direct);
                    }
                }
            } finally {
                ok("POST", "/proxy/stop", null, 200);
                origin.close();
                workers.shutdownNow();
            }
        }
    }

    @Test
    void asynchronousDiagnosticsCanBeCancelledWithoutBlockingControl() throws Exception {
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

    @Test
    void routingDiagnosticsUseCurrentDatabaseRules() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0,\"routesInline\":\"127.0.0.0/8\"}", 200);
        ok("POST", "/proxy/start", null, 200);
        String job = ok("POST", "/routing/resolve", "{\"target\":\"127.0.0.1:80\"}", 202).getAsJsonObject("data").get("id").getAsString();
        assertEquals("direct", awaitJob(job).getAsJsonObject("result").get("action").getAsString());
        ok("PUT", "/routing/direct-rules", "{\"rules\":\"\"}", 200);
        job = ok("POST", "/routing/resolve", "{\"target\":\"127.0.0.1:80\"}", 202).getAsJsonObject("data").get("id").getAsString();
        assertEquals("proxy", awaitJob(job).getAsJsonObject("result").get("action").getAsString());
    }

    @Test
    void targetRoutesPreserveRuleTextPersistAndRestoreAutomaticRules() throws Exception {
        addProfile("a", "http2", 4433, false);
        JsonObject settings = new JsonObject();
        settings.addProperty("routesInline", "example.com\n127.0.0.0/8\n");
        ok("PATCH", "/settings", settings.toString(), 200);
        long original = revision;
        String proxy = "{\"target\":\"WWW.Example.COM.:443\",\"route\":\"proxy\"}";
        assertEquals(428, request("PUT", "/routing/targets", proxy).statusCode());
        ok("PUT", "/routing/targets", proxy, 200);
        assertEquals(409, request("PUT", "/routing/targets", proxy, "If-Match", "" + original).statusCode());
        long changed = revision;
        ok("PUT", "/routing/targets", proxy, 200);
        assertEquals(changed, revision);
        ok("PUT", "/routing/targets", "{\"target\":\"[2001:db8::1]:443\",\"route\":\"direct\"}", 200);
        var routing = ok("GET", "/routing", null, 200).getAsJsonObject("data");
        assertEquals("proxy", routing.getAsJsonObject("targetRoutes").get("www.example.com").getAsString());
        String forcedJob = ok("POST", "/routing/resolve", "{\"target\":\"www.example.com:443\"}", 202).getAsJsonObject("data").get("id").getAsString();
        var forcedResult = awaitJob(forcedJob).getAsJsonObject("result");
        assertEquals("proxy", forcedResult.get("action").getAsString());
        assertEquals("target_rule", forcedResult.get("matchedBy").getAsString());
        var loaded = persisted();
        assertEquals("example.com\n127.0.0.0/8\n", loaded.local().values().getProperty("routesInline"));
        var snapshot = com.blacicada.config.DirectRoutes.load(loaded.local());
        assertFalse(snapshot.matches("www.example.com"));
        assertTrue(snapshot.matches("2001:0db8::1"));
        ok("PUT", "/routing/targets", "{\"target\":\"www.example.com:80\",\"route\":\"auto\"}", 200);
        assertFalse(ok("GET", "/routing", null, 200).getAsJsonObject("data").getAsJsonObject("targetRoutes").has("www.example.com"));
        String job = ok("POST", "/routing/resolve", "{\"target\":\"www.example.com:443\"}", 202).getAsJsonObject("data").get("id").getAsString();
        assertEquals("direct", awaitJob(job).getAsJsonObject("result").get("action").getAsString());
        changed = revision;
        ok("PUT", "/routing/targets", "{\"target\":\"example.com:443\",\"route\":\"wrong\"}", 400);
        ok("PUT", "/routing/targets", "{\"target\":\"bad/host:443\",\"route\":\"proxy\"}", 400);
        assertEquals(changed, revision);
    }

    @Test
    void diagnosticTcpFailureAndRoutingResultAreObservable() throws Exception {
        int closedPort;
        try (var port = new ServerSocket(0)) {
            closedPort = port.getLocalPort();
        }
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

    @Test
    void concurrentWritersCannotOverwriteTheSameRevision() throws Exception {
        addProfile("a", "http2", 4433, false);
        long sameVersion = revision;
        try (var workers = Executors.newVirtualThreadPerTaskExecutor()) {
            var one = workers.submit(() -> request("PATCH", "/profiles/a", "{\"name\":\"页面一\"}", "If-Match", "" + sameVersion));
            var two = workers.submit(() -> request("PATCH", "/profiles/a", "{\"name\":\"页面二\"}", "If-Match", "" + sameVersion));
            var codes = new ArrayList<>(List.of(one.get().statusCode(), two.get().statusCode()));
            Collections.sort(codes);
            assertEquals(List.of(200, 409), codes);
        }
    }

    private String routingRequest(JsonObject document, String strategy) {
        var request = new JsonObject();
        request.add("document", document);
        request.addProperty("strategy", strategy);
        return request.toString();
    }

    @Test
    void routingExportImportIsAtomicVersionedAndPersistsAcrossRestart() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PUT", "/routing/mode", "{\"mode\":\"direct\"}", 200);
        JsonObject document = JsonParser.parseString("""
                {"version":2,"kind":"network-routes","directRules":"# 注释\\nexample.com\\n",
                 "targetRoutes":{"WWW.Example.COM.":"proxy","::1":"direct"}}
                """).getAsJsonObject();
        long before = revision;
        assertEquals(428, request("POST", "/routing/import", routingRequest(document, "replace")).statusCode());
        var preview = ok("POST", "/routing/preview", routingRequest(document, "replace"), 200).getAsJsonObject("data");
        assertEquals(before, revision);
        ok("POST", "/routing/import", routingRequest(document, "replace"), 200);
        assertEquals(before + 1, revision);
        JsonObject exported = ok("GET", "/routing/export", null, 200).getAsJsonObject("data");
        assertEquals(preview, exported);
        assertFalse(exported.toString().contains("test-secret"));
        assertFalse(exported.has("mode"));
        assertFalse(exported.has("defaultConnectionId"));
        assertEquals("direct", control.routing().get("mode"));
        assertEquals("a", control.routing().get("defaultConnectionId"));
        for (String invalid : List.of("version", "kind", "directRules", "targetRoutes")) {
            JsonObject broken = exported.deepCopy();
            switch (invalid) {
                case "version" -> broken.addProperty(invalid, 1);
                case "kind" -> broken.addProperty(invalid, "invalid");
                case "directRules" -> broken.addProperty(invalid, "10.0.0.0/99");
                case "targetRoutes" -> broken.getAsJsonObject(invalid).addProperty("bad/host", "proxy");
            }
            long unchanged = revision;
            ok("POST", "/routing/import", routingRequest(broken, "replace"), 400);
            assertEquals(unchanged, revision);
            assertEquals(exported, ok("GET", "/routing/export", null, 200).getAsJsonObject("data"));
        }
        assertEquals(409, request("POST", "/routing/import", routingRequest(exported, "replace"), "If-Match", "" + before).statusCode());
        var addition = document.deepCopy();
        addition.addProperty("directRules", "EXAMPLE.com. # 重复\nother.test # 新规则");
        addition.getAsJsonObject("targetRoutes").addProperty("www.example.com", "direct");
        addition.getAsJsonObject("targetRoutes").remove("WWW.Example.COM.");
        ok("POST", "/routing/import", routingRequest(addition, "merge"), 200);
        var merged = ok("GET", "/routing/export", null, 200).getAsJsonObject("data");
        assertTrue(merged.get("directRules").getAsString().contains("# 注释"));
        assertTrue(merged.get("directRules").getAsString().contains("other.test # 新规则"));
        assertFalse(merged.get("directRules").getAsString().contains("# 重复"));
        assertEquals("direct", merged.getAsJsonObject("targetRoutes").get("www.example.com").getAsString());
        ok("POST", "/routing/import", routingRequest(exported, "replace"), 200);
        long saved = revision;
        web.close();
        control = new KernelControl(directory.resolve("kernel.db"));
        web = new ControlHttpServer(control, 0, token, Set.of());
        web.start();
        assertEquals(saved, control.metadata().get("revision"));
        assertEquals(exported, ok("GET", "/routing/export", null, 200).getAsJsonObject("data"));
    }

    @Test
    void profileExportOnlyReturnsExplicitlySelectedSecrets() throws Exception {
        addProfile("a", "http2", 4433, false);
        addProfile("b", "http2", 4434, false);
        var without = ok("POST", "/profiles/export", "{\"ids\":[\"a\"],\"includePassword\":false}", 200).getAsJsonObject("data");
        assertEquals(1, without.getAsJsonArray("connections").size());
        assertFalse(without.toString().contains("password"));
        assertFalse(without.getAsJsonArray("connections").get(0).getAsJsonObject().has("id"));
        var with = ok("POST", "/profiles/export", "{\"ids\":[\"a\",\"b\"],\"includePassword\":true}", 200).getAsJsonObject("data");
        assertEquals(2, with.getAsJsonArray("connections").size());
        assertEquals("test-secret", with.getAsJsonArray("connections").get(0).getAsJsonObject().getAsJsonObject("config").get("password").getAsString());
        assertFalse(control.configuration().toString().contains("test-secret"));
        assertFalse(control.snapshot().toString().contains("test-secret"));
        ok("POST", "/profiles/export", "{\"ids\":[],\"includePassword\":true}", 400);
        ok("POST", "/profiles/export", "{\"ids\":[\"missing\"],\"includePassword\":true}", 404);
        ok("POST", "/profiles/export", "{\"ids\":[\"a\"]}", 400);
    }

    @Test
    void failedDatabaseWriteDoesNotChangeConfigurationOrVersion() throws Exception {
        addProfile("a", "http2", 4433, false);
        var before = control.configuration();
        long unchanged = revision;
        try (var db = java.sql.DriverManager.getConnection("jdbc:sqlite:" + directory.resolve("kernel.db"));
             var sql = db.createStatement()) {
            sql.execute("CREATE TRIGGER reject_settings BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT,'测试写入失败'); END");
            ok("PATCH", "/settings", "{\"port\":12345}", 503);
            assertEquals(unchanged, revision);
            assertEquals(before, control.configuration());
            sql.execute("DROP TRIGGER reject_settings");
            ok("PATCH", "/settings", "{\"port\":12345}", 200);
            assertEquals(unchanged + 1, revision);
        }
    }

    @Test
    void failedCommitRestoresRunningConfiguration() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0,\"routingMode\":\"direct\"}", 200);
        ok("POST", "/proxy/start", null, 200);
        long unchanged = revision;
        try (var reader = java.sql.DriverManager.getConnection("jdbc:sqlite:" + directory.resolve("kernel.db"))) {
            reader.setAutoCommit(false);
            try (var query = reader.createStatement(); var rows = query.executeQuery("SELECT revision FROM metadata")) {
                assertTrue(rows.next());
                // 持有读取事务，使候选配置写入后无法获得提交所需的排他锁。
                ok("PUT", "/routing/mode", "{\"mode\":\"rules\"}", 503);
                assertEquals(unchanged, revision);
                assertEquals("direct", control.routing().get("mode"));
                assertTrue((boolean) control.status().get("running"));
                assertEquals("unused", control.status().get("connection"));
            }
            reader.rollback();
        }
        assertEquals("direct", persisted().routingMode());
    }

    @Test
    void diagnosticsLimitAndCancellationReleaseWorkSlots() throws Exception {
        try (var blackhole = new ServerSocket(0)) {
            addProfile("a", "http2", blackhole.getLocalPort(), false);
            ok("PATCH", "/profiles/a", "{\"config\":{\"connectTimeoutMillis\":10000}}", 200);
            List<String> ids = new ArrayList<>();
            for (int i = 0; i < 4; i++)
                ids.add(ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 202)
                        .getAsJsonObject("data").get("id").getAsString());
            ok("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}", 429);
            for (String id : ids) ok("DELETE", "/operations/" + id, null, 200);
            HttpResponse<String> retry = null;
            for (int i = 0; i < 100; i++) {
                retry = request("POST", "/profiles/a/tests", "{\"target\":\"127.0.0.1:80\"}");
                if (retry.statusCode() == 202) break;
                assertEquals(429, retry.statusCode());
                Thread.sleep(20);
            }
            assertNotNull(retry);
            assertEquals(202, retry.statusCode());
            String next = JsonParser.parseString(retry.body()).getAsJsonObject().getAsJsonObject("data").get("id").getAsString();
            ok("DELETE", "/operations/" + next, null, 200);
        }
    }

    @Test
    void logsFilterExactLevelsAndKeepPaginationAcrossSkippedRecords() throws Exception {
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
        for (var entry : both)
            assertTrue(Set.of("WARN", "ERROR").contains(entry.getAsJsonObject().get("level").getAsString()));
        var empty = ok("GET", "/logs?levels=FATAL", null, 200).getAsJsonObject("data");
        assertTrue(empty.getAsJsonArray("items").isEmpty());
        assertEquals(empty.get("latestCursor"), empty.get("cursor"));
        assertEquals(5, ok("GET", "/logs", null, 200).getAsJsonObject("data").getAsJsonArray("items").size());
        for (String invalid : List.of("ALL", "warn,unknown", "", "WARN,")) {
            var response = ok("GET", "/logs?levels=" + invalid, null, 400);
            assertEquals("INVALID_LOG_LEVEL", response.getAsJsonObject("error").get("code").getAsString());
        }
    }

    @Test
    void rejectsRemovedStandaloneAndPipeModes() {
        for (String[] args : List.of(new String[]{"--ui"}, new String[]{"kernel.db"}, new String[0])) {
            var error = assertThrows(IllegalArgumentException.class, () -> com.blacicada.ClientApplication.main(args));
            assertTrue(error.getMessage().contains("--web"));
        }
    }

    @Test
    void eventDisconnectDoesNotStopProxyAndLogsAreRedactedAndPaged() throws Exception {
        addProfile("a", "http2", 4433, false);
        ok("PATCH", "/settings", "{\"port\":0}", 200);
        ok("POST", "/proxy/start", null, 200);
        var response = client.send(HttpRequest.newBuilder(URI.create(web.url() + "/api/v1/events"))
                .header("Authorization", "Bearer " + token).build(), HttpResponse.BodyHandlers.ofInputStream());
        assertEquals(200, response.statusCode());
        try (var reader = new BufferedReader(new InputStreamReader(response.body()))) {
            assertTrue(reader.readLine().startsWith("id:"));
            assertEquals("event: snapshot", reader.readLine());
            assertTrue(reader.readLine().contains("\"running\":true"));
        }
        assertTrue(ok("GET", "/status", null, 200).getAsJsonObject("data").get("running").getAsBoolean());
        for (int i = 0; i < 3; i++)
            org.apache.logging.log4j.LogManager.getLogger(getClass()).warn("测试日志 test-secret {}", i);
        JsonObject logs = null;
        // Log4j 异步投递日志，等待记录进入管理日志缓冲后再检查分页。
        for (int i = 0; i < 100; i++) {
            logs = ok("GET", "/logs?limit=1", null, 200).getAsJsonObject("data");
            if (logs.get("latestCursor").getAsLong() >= 3) break;
            Thread.sleep(20);
        }
        assertNotNull(logs);
        assertFalse(logs.toString().contains("test-secret"));
        assertEquals(1, logs.getAsJsonArray("items").size());
        long after = logs.get("cursor").getAsLong();
        var next = ok("GET", "/logs?limit=1&after=" + after, null, 200).getAsJsonObject("data");
        assertTrue(next.get("cursor").getAsLong() > after);
    }
}
