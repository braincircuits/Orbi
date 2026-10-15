package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.h2.Http2ProxyServer;
import com.blacicada.h3.Http3ProxyServer;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(30)
class RouteUpdateIntegrationTest {
    @TempDir Path directory;
    private String resource(String file) throws Exception { return Path.of(getClass().getResource("/tls/" + file).toURI()).toString(); }

    /** 两种协议共用真实回环网络夹具，不访问公网。 */
    private final class Fixture implements AutoCloseable {
        // 目标明确使用 IPv4 回环监听，避免双栈通配端口与其他 IPv4 服务重叠。
        final ServerSocket origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
        final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
        final AutoCloseable server;
        final LongSupplier accepted;
        final LocalProxyServer proxy;
        final KernelConfig config;
        final List<Map<String, Object>> access = new CopyOnWriteArrayList<>();
        Fixture(String protocol, int streams) throws Exception {
            Properties values = new Properties();
            values.setProperty("bind", "127.0.0.1"); values.setProperty("port", "0"); values.setProperty("password", "rules-test");
            values.setProperty("maxStreams", "" + streams);
            values.setProperty("tls.cert", resource("localhost.crt")); values.setProperty("tls.key", resource("localhost.key"));
            int port;
            if (protocol.equals("http2")) {
                var h2 = new Http2ProxyServer(new ProxyConfig(values, directory)).start(); server = h2; port = h2.address().getPort(); accepted = h2::acceptedConnections;
            } else {
                var h3 = new Http3ProxyServer(new ProxyConfig(values, directory)).start(); server = h3; port = h3.address().getPort(); accepted = h3::acceptedConnections;
            }
            Properties connection = new Properties();
            connection.setProperty("protocol", protocol); connection.setProperty("server.host", "127.0.0.1");
            connection.setProperty("server.port", "" + port); connection.setProperty("password", "rules-test");
            connection.setProperty("tls.ca", resource("localhost.crt")); connection.setProperty("tls.serverName", "localhost");
            connection.setProperty("connectTimeoutMillis", "4000");
            Properties local = new Properties(); local.setProperty("port", "0"); local.setProperty("connectTimeoutMillis", "4000");
            config = new KernelConfig(new ProxyConfig(local, directory), List.of(new KernelConfig.Profile("test", "测试节点", new ProxyConfig(connection, directory))), "test");
            proxy = new LocalProxyServer(config, null, access::add).start();
            workers.submit(() -> {
                while (!origin.isClosed()) try {
                    Socket socket = origin.accept(); workers.submit(() -> {
                        try (socket) { socket.getInputStream().transferTo(socket.getOutputStream()); } catch (IOException ignored) { }
                    });
                } catch (IOException e) { break; }
            });
        }
        void rules(String text) throws Exception {
            Properties local = config.local().values(); local.setProperty("routesInline", text);
            proxy.apply(new KernelConfig(new ProxyConfig(local, directory), config.connections(), "test"));
        }
        Socket request(String host) throws Exception {
            Socket socket = new Socket(); socket.connect(proxy.address()); socket.setSoTimeout(5000);
            socket.getOutputStream().write(("CONNECT " + host + ":" + origin.getLocalPort() + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            return socket;
        }
        Socket tunnel(String host) throws Exception {
            Socket socket = request(host);
            try { assertTrue(headers(socket).startsWith("HTTP/1.1 200")); return socket; }
            catch (Throwable failure) { socket.close(); throw failure; }
        }
        @Override public void close() throws Exception {
            proxy.close(); server.close(); origin.close(); workers.shutdownNow(); workers.close();
        }
    }
    private static String headers(Socket socket) throws IOException {
        StringBuilder text = new StringBuilder(); int b;
        while ((b = socket.getInputStream().read()) >= 0) {
            text.append((char) b); if (text.toString().endsWith("\r\n\r\n")) break;
        }
        return text.toString();
    }
    private static void echo(Socket socket) throws IOException { socket.getOutputStream().write(42); assertEquals(42, socket.getInputStream().read()); }
    private static void await(BooleanSupplier condition) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (!condition.getAsBoolean() && System.nanoTime() < deadline) Thread.sleep(5);
        assertTrue(condition.getAsBoolean());
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void trafficCountsOrdinaryHttpHeadersAndBodyOnce(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32); var origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")); var browser = new Socket()) {
            browser.connect(fixture.proxy.address()); browser.setSoTimeout(5000); origin.setSoTimeout(5000);
            browser.getOutputStream().write(("POST http://127.0.0.1:" + origin.getLocalPort()
                    + "/ HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc").getBytes(StandardCharsets.US_ASCII));
            long uploaded;
            byte[] response = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nxyz".getBytes(StandardCharsets.US_ASCII);
            try (Socket remote = origin.accept()) {
                remote.setSoTimeout(5000);
                uploaded = headers(remote).getBytes(StandardCharsets.US_ASCII).length + 3;
                assertEquals("abc", new String(remote.getInputStream().readNBytes(3), StandardCharsets.US_ASCII));
                remote.getOutputStream().write(response);
                assertArrayEquals(response, browser.getInputStream().readNBytes(response.length));
            }
            long expected = uploaded;
            await(() -> { fixture.proxy.traffic().sample(); return fixture.proxy.traffic().snapshot().get("sentBytes").equals(expected); });
            assertEquals((long) response.length, fixture.proxy.traffic().snapshot().get("receivedBytes"));
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void trafficIncludesProxyAndDirectPayloadWithoutConnectHandshake(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32)) {
            fixture.rules("localhost");
            try (Socket proxied = fixture.tunnel("127.0.0.1"); Socket direct = fixture.tunnel("localhost")) {
                byte[] bytes = new byte[32768]; new Random(42).nextBytes(bytes);
                for (Socket socket : List.of(proxied, direct)) {
                    socket.getOutputStream().write(bytes);
                    assertArrayEquals(bytes, socket.getInputStream().readNBytes(bytes.length));
                }
                await(() -> {
                    fixture.proxy.traffic().sample();
                    return fixture.proxy.traffic().snapshot().get("sentBytes").equals(65536L);
                });
                assertEquals(65536L, fixture.proxy.traffic().snapshot().get("receivedBytes"));
                var recorded = fixture.access.stream().filter(item -> item.get("state").equals("connected")).toList();
                assertEquals(2, recorded.size());
                assertEquals(Set.of("direct", "proxy"), recorded.stream().map(item -> item.get("route")).collect(java.util.stream.Collectors.toSet()));
                assertTrue(recorded.stream().allMatch(item -> item.get("method").equals("CONNECT")));
                String session = (String) fixture.proxy.traffic().snapshot().get("sessionId");
                fixture.rules("");
                assertEquals(session, fixture.proxy.traffic().snapshot().get("sessionId"));
            }
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void globalModesOverrideRulesAndLatencyUsesCurrentTransport(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32)) {
            assertTrue(fixture.proxy.latency().get(5, TimeUnit.SECONDS) > 0);
            assertTrue(fixture.proxy.tunnels().isEmpty());
            fixture.rules("localhost");
            try (Socket direct = fixture.tunnel("localhost")) {
                echo(direct);
                Properties local = fixture.proxy.configuration().local().values();
                local.setProperty("routingMode", "proxy");
                var forced = new KernelConfig(new ProxyConfig(local, directory), fixture.config.connections(), "test");
                fixture.proxy.apply(forced);
                assertEquals(-1, direct.getInputStream().read());
                try (Socket proxied = fixture.tunnel("localhost")) {
                    echo(proxied); assertEquals("proxy", fixture.proxy.tunnels().getFirst().get("route"));
                    local.setProperty("routingMode", "direct");
                    fixture.proxy.apply(new KernelConfig(new ProxyConfig(local, directory), fixture.config.connections(), "test"));
                    assertEquals(-1, proxied.getInputStream().read());
                    assertEquals("unused", fixture.proxy.connectionState());
                    assertThrows(ExecutionException.class, () -> fixture.proxy.latency().get(1, TimeUnit.SECONDS));
                }
                try (Socket bypass = fixture.tunnel("127.0.0.1")) {
                    echo(bypass); assertEquals("direct", fixture.proxy.tunnels().getFirst().get("route"));
                    local.setProperty("routingMode", "rules");
                    fixture.proxy.apply(new KernelConfig(new ProxyConfig(local, directory), fixture.config.connections(), "test"));
                    assertEquals(-1, bypass.getInputStream().read());
                    try (Socket restored = fixture.tunnel("127.0.0.1")) { echo(restored); }
                }
            }
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void domainChangesOnlyCloseAffectedTunnelsAndKeepSharedConnection(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32);
             Socket affected = fixture.tunnel("localhost"); Socket unaffected = fixture.tunnel("127.0.0.1")) {
            echo(affected); echo(unaffected);
            var initial = fixture.proxy.tunnels();
            assertEquals(2, initial.size());
            for (var item : initial) {
                assertEquals("active", item.get("state")); assertEquals("proxy", item.get("route"));
                assertEquals(protocol, item.get("protocol")); assertEquals("test", item.get("profileId"));
                assertEquals("tcp", item.get("originalProtocol"));
                assertTrue(((String) item.get("source")).startsWith("127.0.0.1:"));
                assertTrue((Long) item.get("createdAt") > 0);
            }
            fixture.rules("localhost");
            assertEquals(-1, affected.getInputStream().read()); echo(unaffected);
            await(() -> fixture.proxy.activeTunnels() == 1);
            try (Socket direct = fixture.tunnel("localhost")) {
                echo(direct); assertEquals(1, fixture.proxy.activeTunnels());
                var mixed = fixture.proxy.tunnels(); assertEquals(2, mixed.size());
                var directItem = mixed.stream().filter(item -> item.get("route").equals("direct")).findFirst().orElseThrow();
                assertEquals("tcp", directItem.get("protocol")); assertEquals("", directItem.get("profileId"));
                assertEquals("tcp", directItem.get("originalProtocol"));
                assertEquals("localhost:" + fixture.origin.getLocalPort(), directItem.get("target"));
                var oldId = initial.stream().filter(item -> item.get("target").equals("localhost:" + fixture.origin.getLocalPort()))
                        .findFirst().orElseThrow().get("id");
                assertFalse(mixed.stream().anyMatch(item -> item.get("id").equals(oldId)));
                fixture.rules("# 注释\nLOCALHOST.\nlocalhost\nexample.com"); echo(direct); echo(unaffected);
                assertThrows(IllegalArgumentException.class, () -> fixture.rules("10.0.0.0/99")); echo(direct); echo(unaffected);
                fixture.rules(""); assertEquals(-1, direct.getInputStream().read()); echo(unaffected);
                try (Socket restored = fixture.tunnel("localhost")) {
                    echo(restored); await(() -> fixture.proxy.activeTunnels() == 2);
                }
            }
            assertEquals(1, fixture.proxy.connectionCount()); assertEquals(1, fixture.accepted.getAsLong());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void ruleUpdateChangesNetworkRoutesAndPreservesUnchangedDirectConnection(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32)) {
            fixture.rules("localhost");
            try (Socket direct = fixture.tunnel("localhost"); Socket affected = fixture.tunnel("127.0.0.1")) {
                echo(affected); fixture.rules("localhost\n127.0.0.1/32"); assertEquals(-1, affected.getInputStream().read()); echo(direct);
                try (Socket networkDirect = fixture.tunnel("127.0.0.1")) {
                    fixture.rules("127.10.0.1/8\nlocalhost"); echo(networkDirect); echo(direct);
                    fixture.rules("localhost");
                    assertEquals(-1, networkDirect.getInputStream().read()); echo(direct);
                }
                assertEquals(1, fixture.accepted.getAsLong());
            }
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void newNetworkResolvesExistingProxyDomainAndClosesOnlyItsStream(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32); Socket affected = fixture.tunnel("localhost")) {
            fixture.rules("127.0.0.0/8\n::1/128"); assertEquals(-1, affected.getInputStream().read());
            try (Socket direct = fixture.tunnel("localhost")) { echo(direct); await(() -> fixture.proxy.activeTunnels() == 0); }
            assertEquals(1, fixture.accepted.getAsLong());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void queuedStreamIsCancelledWithoutClosingOtherStreams(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 1); Socket active = fixture.tunnel("127.0.0.1"); Socket waiting = fixture.request("localhost")) {
            await(() -> fixture.proxy.pendingTunnels() == 1);
            var queued = fixture.proxy.tunnels(); assertEquals(2, queued.size());
            assertEquals(1, queued.stream().filter(item -> item.get("state").equals("pending")).count());
            fixture.rules("localhost");
            assertFalse(new String(waiting.getInputStream().readAllBytes(), StandardCharsets.US_ASCII).contains("200 OK"));
            await(() -> fixture.proxy.pendingTunnels() == 0); echo(active);
            await(() -> fixture.proxy.tunnels().size() == 1);
            try (Socket direct = fixture.tunnel("localhost")) { echo(direct); echo(active); }
            fixture.rules(""); active.close();
            try (Socket restored = fixture.tunnel("localhost")) { echo(restored); }
            assertEquals(1, fixture.accepted.getAsLong());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void ruleChangesAlsoInterruptOrdinaryHttpResponse(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, 32); var origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
             Socket browser = new Socket()) {
            browser.connect(fixture.proxy.address()); browser.setSoTimeout(5000); origin.setSoTimeout(5000);
            browser.getOutputStream().write(("GET http://localhost:" + origin.getLocalPort() + "/ HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            try (Socket remote = origin.accept()) {
                remote.setSoTimeout(5000); headers(remote);
                remote.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\na".getBytes(StandardCharsets.US_ASCII));
                assertTrue(headers(browser).startsWith("HTTP/1.1 200")); assertEquals('a', browser.getInputStream().read());
                assertEquals("localhost:" + origin.getLocalPort(), fixture.proxy.tunnels().getFirst().get("target"));
                fixture.rules("example.com"); remote.getOutputStream().write('b'); assertEquals('b', browser.getInputStream().read());
                fixture.rules("localhost"); assertEquals(-1, browser.getInputStream().read()); assertEquals(-1, remote.getInputStream().read());
                assertEquals(1, fixture.accepted.getAsLong());
            }
        }
    }
}
