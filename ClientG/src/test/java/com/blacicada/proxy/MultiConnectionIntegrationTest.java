package com.blacicada.proxy;

import com.blacicada.h3.Http3ProxyServer;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.h2.Http2ProxyServer;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.net.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(30)
class MultiConnectionIntegrationTest {
    @TempDir Path directory;
    private String resource(String file) throws Exception { return Path.of(getClass().getResource("/tls/" + file).toURI()).toString(); }
    private Properties serverValues() throws Exception {
        Properties p = new Properties(); p.setProperty("password", "switch-test"); p.setProperty("port", "0"); p.setProperty("bind", "127.0.0.1");
        p.setProperty("maxStreams", "1"); p.setProperty("tls.cert", resource("localhost.crt")); p.setProperty("tls.key", resource("localhost.key")); return p;
    }
    private KernelConfig.Profile profile(String protocol, int port) throws Exception {
        Properties p = new Properties(); p.setProperty("protocol", protocol); p.setProperty("server.host", "127.0.0.1");
        p.setProperty("server.port", "" + port); p.setProperty("password", "switch-test"); p.setProperty("tls.ca", resource("localhost.crt"));
        p.setProperty("tls.serverName", "localhost"); p.setProperty("connectTimeoutMillis", "2000");
        return new KernelConfig.Profile(protocol, protocol, new ProxyConfig(p, directory));
    }
    private static Socket tunnel(LocalProxyServer proxy, int port, String host) throws Exception {
        Socket s = new Socket(); s.connect(proxy.address()); s.setSoTimeout(4000);
        s.getOutputStream().write(("CONNECT " + host + ":" + port + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes());
        StringBuilder headers = new StringBuilder();
        int b; while ((b = s.getInputStream().read()) >= 0) { headers.append((char)b); if (headers.toString().endsWith("\r\n\r\n")) break; }
        assertTrue(headers.toString().startsWith("HTTP/1.1 200"), headers.toString()); return s;
    }
    private static void echo(Socket s) throws Exception { s.getOutputStream().write(42); assertEquals(42, s.getInputStream().read()); }
    @Test void switchingBothDirectionsClosesOldTunnelsButPreservesListenerAndDirectTraffic() throws Exception {
        try (var origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
             var workers = Executors.newVirtualThreadPerTaskExecutor();
             var h3 = new Http3ProxyServer(new ProxyConfig(serverValues(), directory)).start()) {
            workers.submit(() -> {
                while (!origin.isClosed()) {
                    try { Socket s = origin.accept(); workers.submit(() -> { try (s) { s.getInputStream().transferTo(s.getOutputStream()); } catch (IOException ignored) { } }); }
                    catch (IOException e) { break; }
                }
            });
            Properties server2 = serverValues(); server2.setProperty("port", "" + h3.address().getPort());
            try (var h2 = new Http2ProxyServer(new ProxyConfig(server2, directory)).start()) {
                Properties local = new Properties(); local.setProperty("port", "0"); local.setProperty("routesInline", "localhost");
                var config = new KernelConfig(new ProxyConfig(local, directory), List.of(profile("http3", h3.address().getPort()), profile("http2", h2.address().getPort())), "http3");
                try (var proxy = new LocalProxyServer(config).start(); Socket direct = tunnel(proxy, origin.getLocalPort(), "localhost")) {
                    var address = proxy.address();
                    for (String next : List.of("http2", "http3", "http2")) {
                        try (Socket old = tunnel(proxy, origin.getLocalPort(), "127.0.0.1")) {
                            echo(old);
                            try (Socket waiting = new Socket()) {
                                waiting.connect(proxy.address()); waiting.setSoTimeout(4000);
                                waiting.getOutputStream().write(("CONNECT 127.0.0.1:" + origin.getLocalPort() + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes());
                                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                                while (proxy.pendingTunnels() == 0 && System.nanoTime() < deadline) Thread.sleep(5);
                                assertTrue(proxy.pendingTunnels() > 0);
                                proxy.apply(config.select(next));
                                String cancelled = new String(waiting.getInputStream().readAllBytes());
                                assertFalse(cancelled.contains("200 OK"), "旧会话排队请求不能在切换后复活");
                            }
                            assertEquals(-1, old.getInputStream().read());
                            assertEquals(address, proxy.address()); echo(direct);
                            try (Socket active = tunnel(proxy, origin.getLocalPort(), "127.0.0.1")) { echo(active); }
                        }
                    }
                }
            } finally { origin.close(); workers.shutdownNow(); }
        }
    }
}
