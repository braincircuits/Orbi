package com.blacicada.config;

import com.blacicada.common.ProxyConfig;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.*;

class DirectRoutesTest {
    @Test
    void mergeKeepsCommentsAndDeduplicatesEquivalentDomainsAndNetworks() throws Exception {
        String merged = DirectRoutes.mergeText("# 原规则\nExample.COM # 旧备注\n192.168.1.99/24\n::1",
                "example.com. # 新备注\n192.168.1.0/24\n0:0:0:0:0:0:0:1\nother.test # 新目标");
        assertTrue(merged.contains("# 原规则"));
        assertTrue(merged.contains("# 旧备注"));
        assertFalse(merged.contains("# 新备注"));
        assertFalse(merged.contains("192.168.1.0/24"));
        assertFalse(merged.contains("0:0:0:0:0:0:0:1"));
        assertTrue(merged.contains("other.test # 新目标"));
    }

    @Test
    void exactTargetOverridesBeatDomainAndNetworkRulesWithoutDns() throws Exception {
        Properties settings = new Properties();
        settings.setProperty("routesInline", "example.com\n0.0.0.0/0\n::/0");
        settings.setProperty("routesOverrides", "proxy WWW.Example.COM.\nproxy 2001:db8::1\ndirect other.test");
        var routes = DirectRoutes.load(new ProxyConfig(settings, directory));
        assertFalse(routes.matches("www.example.com"));
        assertFalse(routes.needsResolution("www.example.com"));
        assertTrue(routes.matches("sub.www.example.com"));
        assertFalse(routes.matches("2001:0db8:0:0:0:0:0:1"));
        assertTrue(routes.matches("2001:db8::2"));
        assertTrue(routes.matches("other.test"));
        assertFalse(routes.needsResolution("other.test"));
        settings.setProperty("routesOverrides", "direct www.example.com");
        assertFalse(routes.sameRules(DirectRoutes.load(new ProxyConfig(settings, directory))));
        settings.setProperty("routesOverrides", "invalid example.com");
        assertThrows(IOException.class, () -> DirectRoutes.load(new ProxyConfig(settings, directory)));
    }

    @Test
    void equivalentRulesIgnoreFormattingOrderDuplicatesAndHostBits() throws Exception {
        var first = new DirectRoutes("Example.COM.\n10.1.2.3/8\n2001:db8::1/32\n");
        var second = new DirectRoutes("# 注释\n2001:db8:1234::/32\n10.0.0.0/8\nexample.com\nexample.com\n10.0.0.1/8");
        assertTrue(first.sameRules(second));
        assertFalse(first.sameRules(new DirectRoutes("example.com\n10.0.0.0/16\n2001:db8::/32")));
    }

    @TempDir
    Path directory;

    private DirectRoutes routes(String rules) throws IOException {
        return new DirectRoutes(rules);
    }

    @Test
    void preservesDomainRulesAndIgnoresComments() throws Exception {
        var routes = routes("# 注释\n\n Example.COM. # 直连域名\n");
        assertTrue(routes.matches("example.com"));
        assertTrue(routes.matches("WWW.Example.com."));
        assertFalse(routes.matches("notexample.com"));
        assertFalse(routes.matches("example.com.evil.test"));
        assertFalse(routes.needsResolution("example.net"));
    }

    @Test
    void matchesIpv4NetworkBoundariesAndHostBits() throws Exception {
        var routes = routes("192.168.5.77/23\n10.0.0.4/31\n");
        for (String host : new String[]{"192.168.4.0", "192.168.5.255", "10.0.0.4", "10.0.0.5"})
            assertTrue(routes.matches(host), host);
        for (String host : new String[]{"192.168.3.255", "192.168.6.0", "10.0.0.3", "10.0.0.6"})
            assertFalse(routes.matches(host), host);
        assertTrue(routes.needsResolution("internal.example"));
        assertFalse(routes.needsResolution("192.168.5.1"));
    }

    @Test
    void matchesIpv6NetworkBoundaries() throws Exception {
        var routes = routes("2001:db8:1234:5678:abcd::1/65\nfd00::/8\n");
        assertTrue(routes.matches("2001:db8:1234:5678:8000::"));
        assertTrue(routes.matches("2001:db8:1234:5678:ffff:ffff:ffff:ffff"));
        assertFalse(routes.matches("2001:db8:1234:5678:7fff:ffff:ffff:ffff"));
        assertFalse(routes.matches("2001:db8:1234:5679:8000::"));
        assertTrue(routes.matches("fd12::5"));
        assertFalse(routes.matches("fcff::5"));
        assertFalse(routes.matches("192.168.1.1"));
    }

    @Test
    void singleAddressesAreExactAndIpv6NotationIsNormalized() throws Exception {
        var routes = routes("127.0.0.1\n2001:db8::1/128\n");
        assertTrue(routes.matches("127.0.0.1"));
        assertFalse(routes.matches("127.0.0.2"));
        assertFalse(routes.matches("evil.127.0.0.1"));
        assertTrue(routes.matches("2001:0db8:0:0:0:0:0:1"));
        assertFalse(routes.matches("2001:db8::2"));
    }

    @Test
    void zeroPrefixesKeepAddressFamiliesSeparate() throws Exception {
        var ipv4 = routes("0.0.0.0/0");
        assertTrue(ipv4.matches("255.255.255.255"));
        assertFalse(ipv4.matches("::1"));
        var ipv6 = routes("::/0");
        assertTrue(ipv6.matches("::1"));
        assertFalse(ipv6.matches("127.0.0.1"));
    }

    @Test
    void invalidCidrFailsWithRuleAndLine() {
        for (String rule : new String[]{"192.168.0.0/33", "::/129", "10.0.0.0/-1", "10.0.0.0/", "10.0.0.0/x", "example.com/24", "999.0.0.0/8", "::/64/2"}) {
            var error = assertThrows(IOException.class, () -> routes("# 规则说明\n" + rule));
            assertTrue(error.getMessage().contains("直连规则:2:"), error.getMessage());
        }
    }

    @Test
    void absentRulesMeanProxyAllAndExternalFileIsIgnored() throws Exception {
        Files.writeString(directory.resolve("pac.txt"), "localhost");
        var routes = DirectRoutes.load(new ProxyConfig(new Properties(), directory));
        assertFalse(routes.matches("127.0.0.1"));
        assertFalse(routes.matches("localhost"));
        assertFalse(routes.needsResolution("localhost"));
        assertEquals("", routes.text());
    }

    @Test
    void preservesOriginalTextAndSnapshot() throws Exception {
        String text = "# 保留注释与换行\r\n example.com # 直连\r\n\r\n";
        Properties settings = new Properties();
        settings.setProperty("routesInline", text);
        var rules = DirectRoutes.load(new ProxyConfig(settings, directory));
        assertTrue(rules.matches("www.example.com"));
        assertEquals(text, rules.text());
        settings.setProperty("routesInline", "other.example");
        assertEquals(text, rules.text());
        assertFalse(rules.matches("other.example"));
    }
}
