package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.config.DirectRoutes;
import com.blacicada.config.KernelConfig;
import com.blacicada.common.ProxyConfig;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.resolver.AbstractAddressResolver;
import io.netty.util.concurrent.ImmediateEventExecutor;
import io.netty.util.concurrent.Promise;
import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class LocalSessionTest {
    private DirectRoutes targetRoutes(String route) throws Exception {
        var values = new java.util.Properties();
        values.setProperty("routesInline", "example.com\n10.0.0.0/8");
        values.setProperty("routesOverrides", route + " www.example.com");
        return DirectRoutes.load(new ProxyConfig(values, java.nio.file.Path.of(".")));
    }

    @Test void targetOverrideClosesChangedRouteAndKeepsSameRouteWithoutDns() throws Exception {
        for (boolean initiallyDirect : new boolean[]{true, false}) {
            var browser = new EmbeddedChannel(); var remote = new EmbeddedChannel();
            try (var resolver = new Resolver()) {
                var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
                session.apply(targetRoutes(initiallyDirect ? "direct" : "proxy"));
                session.remote(remote);
                session.apply(targetRoutes(initiallyDirect ? "direct" : "proxy"));
                assertTrue(browser.isActive()); assertTrue(remote.isActive());
                session.apply(targetRoutes(initiallyDirect ? "proxy" : "direct"));
                assertFalse(browser.isActive()); assertFalse(remote.isActive());
                assertTrue(resolver.requests.isEmpty()); assertEquals(1, decisions.size());
            } finally { browser.finishAndReleaseAll(); remote.finishAndReleaseAll(); }
        }
    }
    @Test void associatedDomainRoutesOriginalIpWithoutResolvingAgain() throws Exception {
        for (String rules : List.of("latest.example", "192.0.2.0/24")) {
            var browser = new EmbeddedChannel();
            try (var resolver = new Resolver()) {
                var decisions = new ArrayList<InetSocketAddress>();
                var session = new LocalSession(browser, new Authority("192.0.2.10", 443), "latest.example", resolver, decisions::add);
                session.apply(new DirectRoutes(rules));
                assertEquals(List.of(new InetSocketAddress("192.0.2.10", 443)), decisions);
                assertTrue(resolver.requests.isEmpty(), "关联域名不能触发重新解析或改变连接 IP");
                session.apply(new DirectRoutes("other.example"));
                assertFalse(browser.isActive());
            } finally { browser.finishAndReleaseAll(); }
        }
    }

    @Test void associatedDomainHonorsGlobalAndExactIpOverrides() throws Exception {
        for (String[] policy : new String[][]{
                {"rules", "proxy latest.example", "proxy"},
                {"rules", "direct latest.example", "direct"},
                {"rules", "proxy latest.example\ndirect 192.0.2.10", "direct"},
                {"rules", "direct latest.example\nproxy 192.0.2.10", "proxy"},
                {"proxy", "direct latest.example", "proxy"},
                {"direct", "proxy latest.example", "direct"}}) {
            var browser = new EmbeddedChannel();
            try (var resolver = new Resolver()) {
                var decisions = new ArrayList<InetSocketAddress>();
                var session = new LocalSession(browser, new Authority("192.0.2.10", 443), "latest.example", resolver, decisions::add);
                var values = new java.util.Properties(); values.setProperty("routingMode", policy[0]);
                values.setProperty("routesInline", "latest.example\n192.0.2.0/24"); values.setProperty("routesOverrides", policy[1]);
                session.apply(DirectRoutes.load(new ProxyConfig(values, java.nio.file.Path.of("."))));
                assertEquals(1, decisions.size()); assertEquals(policy[2].equals("direct"), decisions.getFirst() != null);
                assertTrue(resolver.requests.isEmpty());
            } finally { browser.finishAndReleaseAll(); }
        }
    }

    /** 可控制 DNS 返回时机，验证真实异步回调不会沿用过期规则。 */
    private static final class Resolver extends AbstractAddressResolver<InetSocketAddress> {
        final List<Promise<List<InetSocketAddress>>> requests = new ArrayList<>();
        Resolver() { super(ImmediateEventExecutor.INSTANCE, InetSocketAddress.class); }
        @Override protected boolean doIsResolved(InetSocketAddress address) { return !address.isUnresolved(); }
        @Override protected void doResolve(InetSocketAddress address, Promise<InetSocketAddress> promise) { throw new UnsupportedOperationException(); }
        @Override protected void doResolveAll(InetSocketAddress address, Promise<List<InetSocketAddress>> promise) {
            promise.setUncancellable(); requests.add(promise);
        }
        void complete(int index, String... ips) {
            requests.get(index).setSuccess(java.util.Arrays.stream(ips).map(ip -> new InetSocketAddress(ip, 443)).toList());
        }
    }
    private static LocalSession session(EmbeddedChannel browser, Resolver resolver, List<InetSocketAddress> decisions) {
        return new LocalSession(browser, new Authority("www.example.com", 443), resolver, decisions::add);
    }

    @Test void overlapAndCosmeticEditsKeepConnectionUntilEffectiveRouteChanges() throws Exception {
        var browser = new EmbeddedChannel(); var remote = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("www.example.com\nexample.com")); session.remote(remote);
            session.apply(new DirectRoutes("# 注释\n EXAMPLE.COM.\nexample.com\n"));
            assertTrue(browser.isActive()); assertTrue(remote.isActive()); assertEquals(1, decisions.size());
            session.apply(new DirectRoutes("other.example"));
            assertFalse(browser.isActive()); assertFalse(remote.isActive());
            assertNull(browser.attr(LocalSession.KEY).get()); assertTrue(resolver.requests.isEmpty());
        } finally { browser.finishAndReleaseAll(); remote.finishAndReleaseAll(); }
    }

    @Test void initialDnsCompletionUsesLatestRulesAndConnectsOnlyOnce() throws Exception {
        var browser = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("10.0.0.0/8"));
            var emptyConfig = new KernelConfig(new ProxyConfig(new java.util.Properties(), java.nio.file.Path.of(".")), List.of(), "");
            assertEquals("resolving", session.snapshot(emptyConfig).get("state"));
            session.apply(new DirectRoutes("192.168.0.0/16"));
            resolver.complete(0, "10.1.2.3", "192.168.1.2");
            assertEquals(List.of(new InetSocketAddress("192.168.1.2", 443)), decisions);
            assertEquals("direct", session.snapshot(emptyConfig).get("route"));
            assertEquals("pending", session.snapshot(emptyConfig).get("state"));
            assertEquals(1, resolver.requests.size()); assertTrue(browser.isActive());
        } finally { browser.finishAndReleaseAll(); }
    }

    @Test void removedNetworkCannotCloseProxyWhenOldDnsReturns() throws Exception {
        var browser = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes(""));
            session.apply(new DirectRoutes("10.0.0.0/8"));
            session.apply(new DirectRoutes(""));
            resolver.complete(0, "10.1.2.3");
            assertTrue(browser.isActive()); assertEquals(1, decisions.size()); assertNull(decisions.getFirst());
        } finally { browser.finishAndReleaseAll(); }
    }

    @Test void addingNetworkClosesExistingProxyAfterDnsAndRejectsLateStream() throws Exception {
        var browser = new EmbeddedChannel(); var lateStream = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("")); session.apply(new DirectRoutes("10.0.0.0/8"));
            assertTrue(browser.isActive()); resolver.complete(0, "10.1.2.3");
            assertFalse(browser.isActive()); assertFalse(session.remote(lateStream)); assertFalse(lateStream.isActive());
            assertEquals(1, decisions.size());
        } finally { browser.finishAndReleaseAll(); lateStream.finishAndReleaseAll(); }
    }

    @Test void directConnectionUsesSelectedAddressRatherThanAnotherDnsCandidate() throws Exception {
        var browser = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("10.0.0.0/8")); resolver.complete(0, "10.1.2.3", "192.168.1.2");
            session.apply(new DirectRoutes("192.168.0.0/16"));
            assertFalse(browser.isActive()); assertEquals(1, decisions.size());
        } finally { browser.finishAndReleaseAll(); }
    }

    @Test void lateDirectConnectChecksActualAddressAgainstLatestRules() throws Exception {
        var browser = new EmbeddedChannel();
        var remote = new EmbeddedChannel() {
            @Override protected java.net.SocketAddress remoteAddress0() { return new InetSocketAddress("192.168.1.2", 443); }
        };
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("example.com"));
            session.apply(new DirectRoutes("10.0.0.0/8")); resolver.complete(0, "10.1.2.3");
            assertTrue(browser.isActive());
            // 建连自己的 DNS 返回不同地址时，不能因为先前路由 DNS 命中而保留连接。
            assertFalse(session.remote(remote)); assertFalse(browser.isActive()); assertFalse(remote.isActive());
            assertEquals(1, decisions.size());
        } finally { browser.finishAndReleaseAll(); remote.finishAndReleaseAll(); }
    }

    @Test void closedBrowserIgnoresLateDnsAndDnsFailureKeepsProxy() throws Exception {
        var browser = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(browser, resolver, decisions);
            session.apply(new DirectRoutes("10.0.0.0/8"));
            resolver.requests.getFirst().setFailure(new java.net.UnknownHostException("测试解析失败"));
            assertTrue(browser.isActive()); assertNull(decisions.getFirst());
            browser.close(); session.apply(new DirectRoutes("example.com")); assertEquals(1, decisions.size());
        } finally { browser.finishAndReleaseAll(); }
        var waiting = new EmbeddedChannel();
        try (var resolver = new Resolver()) {
            var decisions = new ArrayList<InetSocketAddress>(); var session = session(waiting, resolver, decisions);
            session.apply(new DirectRoutes("10.0.0.0/8")); waiting.close(); resolver.complete(0, "10.1.2.3");
            assertTrue(decisions.isEmpty()); assertNull(waiting.attr(LocalSession.KEY).get());
        } finally { waiting.finishAndReleaseAll(); }
    }
}
