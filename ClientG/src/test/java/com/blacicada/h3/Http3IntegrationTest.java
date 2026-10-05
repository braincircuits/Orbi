package com.blacicada.h3;

import com.blacicada.common.h3.ProxyConfig;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(45)
class Http3IntegrationTest {
    @TempDir Path directory;
    private Http3ProxyServer server;
    private LocalProxyServer client;
    private Origin echo;

    @BeforeEach void start() throws Exception {
        echo = new Origin(socket -> {
            byte[] bytes = new byte[8192];
            int n;
            while ((n = socket.getInputStream().read(bytes)) != -1) {
                socket.getOutputStream().write(bytes, 0, n);
                socket.getOutputStream().flush();
            }
            socket.shutdownOutput();
        });
        var options = new Properties();
        options.setProperty("password", "integration-test-secret");
        options.setProperty("bind", "127.0.0.1"); options.setProperty("port", "0");
        options.setProperty("tls.cert", resource("localhost.crt"));
        options.setProperty("tls.key", resource("localhost.key"));
        options.setProperty("connectTimeoutMillis", "3000");
        server = new Http3ProxyServer(new ProxyConfig(options, directory)).start();
        client = new LocalProxyServer(clientConfig("integration-test-secret", "localhost", false, 32)).start();
    }
    private String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }
    private ProxyConfig clientConfig(String password, String name, boolean direct, int streams) throws Exception {
        var options = new Properties();
        options.setProperty("password", password); options.setProperty("port", "0");
        options.setProperty("server.host", "127.0.0.1");
        options.setProperty("server.port", Integer.toString(server.address().getPort()));
        options.setProperty("tls.ca", resource("localhost.crt"));
        options.setProperty("tls.serverName", name);
        options.setProperty("connectTimeoutMillis", "3000");
        options.setProperty("maxStreams", Integer.toString(streams));
        if (direct) {
            Path routes = directory.resolve("direct.txt"); Files.writeString(routes, "# comment\n\n127.0.0.1\n");
            options.setProperty("routesFile", routes.toString());
        }
        return new ProxyConfig(options, directory);
    }
    @AfterEach void stop() throws Exception {
        if (client != null) client.close();
        if (server != null) server.close();
        if (echo != null) echo.close();
    }
    private Socket socket(LocalProxyServer proxy) throws Exception {
        Socket s = new Socket(); s.connect(proxy.address()); s.setSoTimeout(12000); return s;
    }
    private Socket tunnel(LocalProxyServer proxy, int targetPort) throws Exception {
        Socket s = socket(proxy);
        send(s, "CONNECT localhost:" + targetPort + " HTTP/1.1\r\nHost: localhost:" + targetPort + "\r\n\r\n");
        String response = headers(s.getInputStream());
        if (!response.startsWith("HTTP/1.1 200")) { s.close(); fail(response); }
        return s;
    }
    private static void send(Socket s, String text) throws IOException {
        s.getOutputStream().write(text.getBytes(StandardCharsets.US_ASCII)); s.getOutputStream().flush();
    }
    private static String headers(InputStream input) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int state = 0, b;
        byte[] ending = {'\r', '\n', '\r', '\n'};
        while ((b = input.read()) != -1) {
            out.write(b);
            state = b == ending[state] ? state + 1 : (b == '\r' ? 1 : 0);
            if (state == 4) return out.toString(StandardCharsets.US_ASCII);
            if (out.size() > 32768) throw new IOException("Oversized header");
        }
        throw new EOFException(out.toString(StandardCharsets.US_ASCII));
    }
    @Test void concurrentTunnelsShareOneConnection() throws Exception {
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var tasks = new ArrayList<java.util.concurrent.Future<?>>();
            for (int i = 0; i < 12; i++) {
                final int value = i;
                tasks.add(executor.submit(() -> {
                    try (Socket s = tunnel(client, echo.port())) {
                        byte[] data = new byte[32768]; Arrays.fill(data, (byte) value);
                        s.getOutputStream().write(data);
                        assertArrayEquals(data, s.getInputStream().readNBytes(data.length));
                    }
                    return null;
                }));
            }
            for (var task : tasks) task.get(20, TimeUnit.SECONDS);
        }
        assertEquals(1, client.connectionCount());
        assertEquals(1, server.acceptedConnections());
    }
    @Test void fragmentedHeadersAndCoalescedTunnelData() throws Exception {
        try (Socket s = socket(client)) {
            send(s, "CON"); Thread.sleep(30);
            send(s, "NECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r"); Thread.sleep(30);
            send(s, "\ncoalesced-payload");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("coalesced-payload", new String(s.getInputStream().readNBytes(17), StandardCharsets.US_ASCII));
        }
    }
    @Test void largeTransferAndHalfClose() throws Exception {
        byte[] data = new byte[4 * 1024 * 1024]; new Random(7).nextBytes(data);
        try (Socket s = tunnel(client, echo.port()); var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var writer = executor.submit(() -> { s.getOutputStream().write(data); s.shutdownOutput(); return null; });
            assertArrayEquals(data, s.getInputStream().readAllBytes());
            writer.get(20, TimeUnit.SECONDS);
        }
    }
    @Test void failedTargetDoesNotBreakSharedConnection() throws Exception {
        int unused;
        try (ServerSocket reservation = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) { unused = reservation.getLocalPort(); }
        try (Socket s = socket(client)) {
            send(s, "CONNECT 127.0.0.1:" + unused + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
        }
        try (Socket s = tunnel(client, echo.port())) { send(s, "ok"); assertEquals("ok", new String(s.getInputStream().readNBytes(2))); }
        assertEquals(1, client.connectionCount());
    }
    @Test void wrongPasswordCannotReachTarget() throws Exception {
        try (var bad = new LocalProxyServer(clientConfig("wrong", "localhost", false, 8)).start(); Socket s = socket(bad)) {
            send(s, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
            assertEquals(0, echo.accepted.get());
        }
    }
    @Test void verifiesCertificateHostname() throws Exception {
        try (var bad = new LocalProxyServer(clientConfig("integration-test-secret", "wrong.invalid", false, 8)).start(); Socket s = socket(bad)) {
            send(s, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
            assertEquals(0, echo.accepted.get());
        }
    }
    @Test void streamsPostBodyWithoutBufferingWholeRequest() throws Exception {
        byte[] body = new byte[2 * 1024 * 1024]; new Random(13).nextBytes(body);
        try (Origin http = new Origin(s -> {
            String head = headers(s.getInputStream());
            assertTrue(head.startsWith("POST /upload?x=1 HTTP/1.1"), head);
            assertFalse(head.toLowerCase(Locale.ROOT).contains("proxy-authorization"));
            assertArrayEquals(body, s.getInputStream().readNBytes(body.length));
            send(s, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        }); Socket s = socket(client)) {
            send(s, "POST http://localhost:" + http.port() + "/upload?x=1 HTTP/1.1\r\nHost: localhost\r\nProxy-Authorization: private\r\nContent-Length: " + body.length + "\r\n\r\n");
            s.getOutputStream().write(body);
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("ok", new String(s.getInputStream().readNBytes(2)));
            http.check();
        }
    }
    @Test void supportsChunkedPost() throws Exception {
        try (Origin http = new Origin(s -> {
            assertTrue(headers(s.getInputStream()).startsWith("POST / HTTP/1.1"));
            assertEquals("5\r\nhello\r\n0\r\n\r\n", new String(s.getInputStream().readNBytes(15), StandardCharsets.US_ASCII));
            send(s, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        }); Socket s = socket(client)) {
            send(s, "POST http://localhost:" + http.port() + "/ HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("ok", new String(s.getInputStream().readNBytes(2))); http.check();
        }
    }
    @Test void routesDirectDomainsWithoutOpeningQuic() throws Exception {
        try (var direct = new LocalProxyServer(clientConfig("integration-test-secret", "localhost", true, 8)).start(); Socket s = socket(direct)) {
            send(s, "CONNECT 127.0.0.1:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            send(s, "direct"); assertEquals("direct", new String(s.getInputStream().readNBytes(6)));
            assertEquals(0, direct.connectionCount());
        }
    }
    @Test void reconnectsAfterConnectionLoss() throws Exception {
        try (Socket first = tunnel(client, echo.port())) {
            send(first, "a"); assertEquals('a', first.getInputStream().read());
            server.disconnectClients();
            assertEquals(-1, first.getInputStream().read());
        }
        try (Socket second = tunnel(client, echo.port())) { send(second, "b"); assertEquals('b', second.getInputStream().read()); }
        assertEquals(2, client.connectionCount());
    }
    @Test void streamLimitDoesNotCloseExistingTunnels() throws Exception {
        try (var limited = new LocalProxyServer(clientConfig("integration-test-secret", "localhost", false, 1)).start();
             Socket active = tunnel(limited, echo.port()); Socket extra = socket(limited)) {
            send(extra, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(extra.getInputStream()).startsWith("HTTP/1.1 502"));
            send(active, "alive"); assertEquals("alive", new String(active.getInputStream().readNBytes(5)));
        }
    }

    @FunctionalInterface interface SocketAction { void run(Socket socket) throws Exception; }
    private static final class Origin implements AutoCloseable {
        final ServerSocket listener;
        final ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor();
        final AtomicInteger accepted = new AtomicInteger();
        final List<java.util.concurrent.Future<?>> tasks = new CopyOnWriteArrayList<>();
        final Set<Socket> sockets = ConcurrentHashMap.newKeySet();
        Origin(SocketAction action) throws IOException {
            listener = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
            executor.submit(() -> {
                while (!listener.isClosed()) {
                    try {
                        Socket socket = listener.accept(); accepted.incrementAndGet(); sockets.add(socket); socket.setSoTimeout(15000);
                        tasks.add(executor.submit(() -> { try (socket) { action.run(socket); } finally { sockets.remove(socket); } return null; }));
                    } catch (IOException e) { if (!listener.isClosed()) throw new UncheckedIOException(e); }
                }
            });
        }
        int port() { return listener.getLocalPort(); }
        void check() throws Exception { for (var task : tasks) task.get(15, TimeUnit.SECONDS); }
        @Override public void close() throws Exception {
            listener.close(); for (Socket socket : sockets) socket.close(); executor.shutdownNow(); executor.awaitTermination(5, TimeUnit.SECONDS);
        }
    }
}
