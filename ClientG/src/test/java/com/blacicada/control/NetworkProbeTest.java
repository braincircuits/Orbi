package com.blacicada.control;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.proxy.LocalProxyServer;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import java.io.*;
import java.net.*;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class NetworkProbeTest {
    @TempDir Path directory;
    @Test void requestUsesLocalProxyAndDoesNotFollowRedirect() throws Exception {
        Properties values = new Properties(); values.setProperty("port", "0"); values.setProperty("routingMode", "direct");
        var config = new KernelConfig(new ProxyConfig(values, directory), List.of(), "");
        try (var origin = new ServerSocket(0); var proxy = new LocalProxyServer(config).start();
             var worker = Executors.newVirtualThreadPerTaskExecutor()) {
            Future<String> received = worker.submit(() -> {
                try (Socket socket = origin.accept()) {
                    var reader = new BufferedReader(new InputStreamReader(socket.getInputStream()));
                    String request = reader.readLine();
                    while (!reader.readLine().isEmpty()) { }
                    socket.getOutputStream().write("HTTP/1.1 302 Found\r\nLocation: https://invalid.example/\r\nContent-Length: 0\r\n\r\n".getBytes());
                    return request;
                }
            });
            var result = NetworkProbe.website(proxy.address(), "local", URI.create("http://127.0.0.1:" + origin.getLocalPort() + "/"));
            assertEquals("HEAD / HTTP/1.1", received.get(2, TimeUnit.SECONDS));
            assertEquals("reachable", result.get("state")); assertEquals(302, result.get("httpStatus"));
            assertTrue((Double) result.get("latencyMillis") > 0);
        }
    }
    @Test void parsesOnlyValidIpAndKeepsMissingLocationUnknown() throws Exception {
        var parsed = NetworkProbe.parseIp("{\"success\":true,\"ip\":\"203.0.113.24\"}");
        assertEquals("203.0.113.24", parsed.get("ip")); assertEquals("", parsed.get("city"));
        assertThrows(IOException.class, () -> NetworkProbe.parseIp("{\"success\":false,\"ip\":\"203.0.113.24\"}"));
        assertThrows(IOException.class, () -> NetworkProbe.parseIp("{\"success\":true,\"ip\":\"example.com\"}"));
        assertThrows(IOException.class, () -> NetworkProbe.parseIp("[]"));
    }
    @Test void cancellingNetworkJobInterruptsRequestAndPreservesContext() throws Exception {
        try (var origin = new ServerSocket(0); var events = new ControlEvents(); var tasks = new ControlTasks(events)) {
            origin.setSoTimeout(5000);
            var context = Map.<String, Object>of("generation", 3L, "mode", "proxy", "kind", "websites");
            var job = tasks.websites(new InetSocketAddress("127.0.0.1", origin.getLocalPort()), context);
            String id = (String) job.get("id");
            try (Socket socket = origin.accept()) {
                tasks.cancelNetwork();
                assertEquals("cancelled", tasks.get(id).get("state"));
                assertEquals(context, tasks.get(id).get("context"));
            }
        }
    }
}
