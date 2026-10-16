package com.blacicada.proxy;

import com.blacicada.common.*;
import com.blacicada.config.KernelConfig;
import com.blacicada.control.ControlEvents;
import com.blacicada.control.ControlLogs;
import com.blacicada.h2.Http2ProxyServer;
import com.blacicada.h3.Http3ProxyServer;
import io.netty.resolver.dns.DnsServerAddresses;
import io.netty.resolver.dns.DnsServerAddressStreamProvider;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.net.*;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static com.blacicada.proxy.KernelDnsTest.*;

/**
 * 用不同的两端系统 DNS 替身验证实际出口，不访问公网或修改系统 DNS。
 */
@Timeout(40)
class DnsRoutingIntegrationTest {
    @TempDir
    Path directory;

    private String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }

    private final class Fixture implements AutoCloseable {
        final Upstream local = new Upstream(), remote = new Upstream();
        final List<String> localNames = new CopyOnWriteArrayList<>(), remoteNames = new CopyOnWriteArrayList<>();
        final AutoCloseable server;
        final LocalProxyServer client;
        KernelConfig config;
        volatile InetSocketAddress firstRemote;
        volatile boolean unavailable;

        Fixture(String protocol, boolean wrongPassword) throws Exception {
            this(protocol, wrongPassword, 1024);
        }

        Fixture(String protocol, boolean wrongPassword, int maxStreams) throws Exception {
            local.ip = "192.0.2.10";
            remote.ip = "198.51.100.20";
            Properties values = new Properties();
            values.setProperty("bind", "127.0.0.1");
            values.setProperty("port", "0");
            values.setProperty("password", "dns-test-secret");
            values.setProperty("tls.cert", resource("localhost.crt"));
            values.setProperty("tls.key", resource("localhost.key"));
            values.setProperty("maxStreams", Integer.toString(maxStreams));
            DnsServerAddressStreamProvider remoteDns = name -> {
                remoteNames.add(name);
                if (unavailable) throw new IllegalStateException("测试服务端 DNS 不可用");
                return (firstRemote == null ? DnsServerAddresses.singleton(remote.address())
                        : DnsServerAddresses.sequential(firstRemote, remote.address())).stream();
            };
            int port;
            if (protocol.equals("http2")) {
                var h2 = new Http2ProxyServer(new ProxyConfig(values, directory), remoteDns).start();
                server = h2;
                port = h2.address().getPort();
            } else {
                var h3 = new Http3ProxyServer(new ProxyConfig(values, directory), remoteDns).start();
                server = h3;
                port = h3.address().getPort();
            }
            Properties profile = new Properties();
            profile.setProperty("protocol", protocol);
            profile.setProperty("server.host", "127.0.0.1");
            profile.setProperty("server.port", "" + port);
            profile.setProperty("password", wrongPassword ? "wrong" : "dns-test-secret");
            profile.setProperty("tls.ca", resource("localhost.crt"));
            profile.setProperty("tls.serverName", "localhost");
            profile.setProperty("connectTimeoutMillis", "4000");
            Properties settings = new Properties();
            settings.setProperty("port", "0");
            settings.setProperty("routesInline", "direct.example\n127.0.0.0/8");
            settings.setProperty("routesOverrides", "proxy forced.direct.example\ndirect exact.example");
            config = new KernelConfig(new ProxyConfig(settings, directory), List.of(
                    new KernelConfig.Profile("dns", "DNS 测试代理", new ProxyConfig(profile, directory))), "dns");
            client = new LocalProxyServer(config, null, null, 0, name -> {
                localNames.add(name);
                return DnsServerAddresses.singleton(local.address()).stream();
            }).start();
        }

        void routing(String mode, String overrides) throws Exception {
            Properties values = config.local().values();
            values.setProperty("routingMode", mode);
            values.setProperty("routesOverrides", overrides);
            config = new KernelConfig(new ProxyConfig(values, directory), config.connections(), config.defaultConnectionId());
            client.apply(config);
        }

        DnsMessage lookup(String domain, boolean udp, int id) throws Exception {
            try (var socket = connect(client, "203.0.113.53:53", udp, frame(query(domain, 1, id)))) {
                var response = new DnsMessage(receive(socket), true);
                assertEquals(id, response.id);
                return response;
            }
        }

        void address(String domain, boolean udp, String expected) throws Exception {
            assertTrue(lookup(domain, udp, 123).addresses().containsKey(expected), "DNS 回答必须来自规则选定的出口");
        }

        @Override
        public void close() throws Exception {
            client.close();
            server.close();
            local.close();
            remote.close();
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void repeatedDnsQueriesReplenishPeerStreamCredit(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false, 4);
             var executor = java.util.concurrent.Executors.newVirtualThreadPerTaskExecutor()) {
            for (boolean udp : List.of(true, false)) {
                for (int i = 0; i < 40; i++) {
                    f.address("query" + udp + i + ".example", udp, f.remote.ip);
                }
                // 同时请求数超过服务端额度，验证排队唤醒及 DNS 短流关闭后的额度回收。
                var requests = new ArrayList<java.util.concurrent.Future<?>>();
                for (int i = 0; i < 16; i++) {
                    String domain = "burst" + udp + i + ".example";
                    requests.add(executor.submit(() -> {
                        f.address(domain, udp, f.remote.ip);
                        return null;
                    }));
                }
                for (var request : requests) request.get(10, TimeUnit.SECONDS);
            }
            assertEquals(112, f.remote.requests.size());
            assertEquals(1, f.client.connectionCount(), "DNS 查询关闭后必须归还流额度并复用连接");
        }
    }

    @org.junit.jupiter.api.Test
    void blockedProxyDnsDoesNotStarveDirectDomainsOrCachedAnswers() throws Exception {
        try (var f = new Fixture("http3", false, 1)) {
            f.address("cached.example", true, f.remote.ip);
            // 占住唯一代理流，让后续代理 DNS 全部等待额度，不需要访问外网。
            try (var occupied = connect(f.client, "198.51.100.1:123", true, new byte[0]);
                 var origin = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
                try (var dns = connect(f.client, "203.0.113.53:53", true, new byte[0])) {
                    for (int id = 0; id < 256; id++) {
                        dns.getOutputStream().write(frame(query("blocked" + id + ".example", 1, id)));
                    }
                    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                    while (f.client.pendingTunnels() < 256 && System.nanoTime() < deadline) Thread.sleep(5);
                    assertEquals(256, f.client.pendingTunnels(), "测试必须真实占满代理 DNS 等待额度");
                    // 同一系统 DNS 通道也必须继续处理放行域名和缓存回答。
                    dns.getOutputStream().write(frame(query("www.direct.example", 1, 1000)));
                    var directReply = new DnsMessage(receive(dns), true);
                    assertEquals(1000, directReply.id);
                    assertTrue(directReply.addresses().containsKey(f.local.ip));
                    f.address("www.direct.example", false, f.local.ip);
                    dns.getOutputStream().write(frame(query("cached.example", 1, 1001)));
                    var cachedReply = new DnsMessage(receive(dns), true);
                    assertEquals(1001, cachedReply.id);
                    assertTrue(cachedReply.addresses().containsKey(f.remote.ip));
                    assertEquals(1, f.remote.requests.size(), "缓存回答不能重新等待代理流");
                    origin.setSoTimeout(1000);
                    try (var direct = connect(f.client, "127.0.0.1:" + origin.getLocalPort(), false, new byte[0]);
                         var accepted = origin.accept()) {
                        accepted.setSoTimeout(1000);
                        direct.getOutputStream().write(42);
                        assertEquals(42, accepted.getInputStream().read(), "代理额度耗尽不能阻塞直连 TCP");
                    }
                }
            }
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void queryDomainRulesChooseClientOrServerSystemDnsForTcpAndUdp(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false)) {
            for (boolean udp : List.of(true, false)) {
                f.address("proxy.example", udp, f.remote.ip);
                assertTrue(f.localNames.isEmpty(), "代理查询不能读取客户端系统 DNS");
                f.address("child.direct.example", udp, f.local.ip);
                f.address("forced.direct.example", udp, f.remote.ip);
                f.address("exact.example", udp, f.local.ip);
                assertFalse(f.localNames.contains("proxy.example"));
                f.localNames.clear();
            }
            assertEquals(4, f.local.requests.size());
            assertEquals(4, f.remote.requests.size());
            assertEquals(Set.of("proxy.example", "forced.direct.example"), new HashSet<>(f.remoteNames));
            assertEquals(1, f.client.connectionCount(), "DNS 查询复用代理主连接");
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void responseCacheIsInvalidatedWhenRulesModeOrConnectionChange(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false)) {
            f.address("cache.example", true, f.remote.ip);
            f.address("cache.example", true, f.remote.ip);
            assertEquals(1, f.remote.requests.size());
            f.routing("rules", "direct cache.example");
            f.address("cache.example", true, f.local.ip);
            f.routing("proxy", "direct cache.example");
            f.address("cache.example", true, f.remote.ip);
            f.routing("direct", "proxy cache.example");
            f.address("cache.example", true, f.local.ip);
            f.routing("rules", "");
            f.address("cache.example", true, f.remote.ip);
            f.client.disconnect();
            f.remote.ip = "198.51.100.21";
            f.address("cache.example", true, f.remote.ip);
            assertEquals(4, f.remote.requests.size());
            assertEquals(2, f.local.requests.size());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void selectingAnotherServerDoesNotReusePreviousServerAnswer(String protocol) throws Exception {
        try (var first = new Fixture(protocol, false); var second = new Fixture(protocol, false)) {
            second.remote.ip = "198.51.100.99";
            first.address("switch.example", true, first.remote.ip);
            var selected = new KernelConfig.Profile("second", "另一个 DNS 出口", second.config.profile("dns").config());
            first.client.apply(new KernelConfig(first.config.local(), List.of(selected), selected.id()));
            first.address("switch.example", true, second.remote.ip);
            assertEquals(1, first.remote.requests.size());
            assertEquals(1, second.remote.requests.size());
            assertTrue(first.localNames.isEmpty());
            assertTrue(second.localNames.isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void applicationsCachedRealIpStillHasDomainAssociationAfterRuleUpdate(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false); var origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))) {
            f.remote.ip = "127.0.0.1";
            f.address("remember.example", true, f.remote.ip);
            f.routing("rules", "direct remember.example");
            try (var browser = connect(f.client, "127.0.0.1:" + origin.getLocalPort(), false, new byte[0]);
                 var accepted = origin.accept()) {
                assertTrue(f.client.tunnels().stream().anyMatch(t -> t.get("target").equals("remember.example:" + origin.getLocalPort())
                        && t.get("route").equals("direct")));
                browser.getOutputStream().write(7);
                assertEquals(7, accepted.getInputStream().read());
            }
            assertEquals(1, f.remote.requests.size());
            assertTrue(f.local.requests.isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void serverDnsAndAuthenticationFailuresNeverFallBackToClientDns(String protocol) throws Exception {
        for (boolean wrongPassword : List.of(false, true))
            try (var events = new ControlEvents();
                 var logs = new ControlLogs(events, text -> text); var f = new Fixture(protocol, wrongPassword)) {
                f.unavailable = true;
                for (boolean udp : List.of(true, false)) {
                    assertEquals(2, f.lookup("failed.example", udp, 8).flags & 15);
                    String message = awaitLog(events, KernelDns.class.getName(), "传输=" + (udp ? "UDP" : "TCP"));
                    assertTrue(message.contains("代理 CONNECT 失败：" + (wrongPassword ? "407" : "502")));
                    assertTrue(message.contains("服务端上游序号=0"));
                    assertTrue(message.contains("服务端上游序号=3"));
                    assertTrue(f.localNames.isEmpty());
                    assertTrue(f.local.requests.isEmpty());
                    assertTrue(f.remote.requests.isEmpty());
                }
                if (wrongPassword) assertTrue(f.remoteNames.isEmpty(), "认证失败不能选择或访问服务端 DNS");
                else {
                    String logger = protocol.equals("http2") ? "com.blacicada.h2.H2ServerConnectHandler" : "com.blacicada.h3.ServerConnectHandler";
                    String message = awaitLog(events, logger, "测试服务端 DNS 不可用");
                    assertTrue(message.contains("failed.example"));
                    assertTrue(message.contains("serverIndex=0"));
                }
            }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void laterMissingServersDoNotHideOriginalDnsTimeout(String protocol) throws Exception {
        try (var events = new ControlEvents(); var logs = new ControlLogs(events, text -> text);
             var f = new Fixture(protocol, false)) {
            f.remote.udp.close();
            assertEquals(2, f.lookup("timeout.example", true, 9).flags & 15);
            String message = awaitLog(events, KernelDns.class.getName(), "域名=timeout.example");
            assertTrue(message.contains("服务端上游序号=0，原因=等待 DNS 响应超时"));
            assertTrue(message.contains("服务端上游序号=1，原因=建立连接失败"));
            assertTrue(message.contains("代理 CONNECT 失败：502"));
            assertTrue(f.localNames.isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void serverDnsRetriesNextUpstreamWithoutChangingRoute(String protocol) throws Exception {
        try (var silent = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0)); var f = new Fixture(protocol, false)) {
            f.firstRemote = (InetSocketAddress) silent.getLocalSocketAddress();
            f.address("retry.example", true, f.remote.ip);
            assertEquals(2, f.remoteNames.size());
            assertTrue(f.localNames.isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void dnsNamesWithUnderscoresAndRootAreNotResolvedAsConnectionHosts(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false)) {
            // 根域问题用空串编码为一个零字节标签。
            for (String name : List.of("_service._tcp.example", "")) {
                f.lookup(name, true, 42);
                assertTrue(f.remoteNames.contains(name));
            }
            String tooLong = String.join(".", Collections.nCopies(5, "a".repeat(63)));
            try (var malformed = connect(f.client, "203.0.113.53:53", true, frame(query(tooLong, 1, 43)))) {
                byte[] error = receive(malformed);
                assertEquals(1, error[3] & 15);
                assertEquals(43, error[1] & 255);
            }
            f.address("after-invalid.example", true, f.remote.ip);
            assertFalse(f.remoteNames.contains(tooLong));
            assertTrue(f.localNames.isEmpty());
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"http2", "http3"})
    void changingRulesCancelsInflightRepliesAndDoesNotRefillOldCache(String protocol) throws Exception {
        try (var f = new Fixture(protocol, false);
             var socket = connect(f.client, "203.0.113.53:53", true, new byte[0])) {
            f.remote.delayMillis = 500;
            socket.getOutputStream().write(frame(query("inflight.example", 1, 1)));
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (f.remote.requests.isEmpty() && System.nanoTime() < deadline) Thread.sleep(10);
            assertFalse(f.remote.requests.isEmpty());
            f.routing("rules", "direct inflight.example");
            assertEquals(2, new DnsMessage(receive(socket), true).flags & 15);
            f.address("inflight.example", true, f.local.ip);
            Thread.sleep(600);
            f.address("inflight.example", true, f.local.ip);
            assertEquals(1, f.local.requests.size());
            assertEquals(1, f.remote.requests.size());
        }
    }
}
