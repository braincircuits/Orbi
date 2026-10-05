package com.blacicada.h3;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.junit.jupiter.api.Assertions.*;

class DirectRoutesTest {
    @TempDir Path directory;
    private DirectRoutes routes(String rules) throws IOException {
        Path file = directory.resolve("pac.txt");
        Files.writeString(file, rules);
        return new DirectRoutes(file);
    }

    @Test void preservesDomainRulesAndIgnoresComments() throws Exception {
        var routes = routes("# 注释\n\n Example.COM. # direct domain\n");
        assertTrue(routes.matches("example.com"));
        assertTrue(routes.matches("WWW.Example.com."));
        assertFalse(routes.matches("notexample.com"));
        assertFalse(routes.matches("example.com.evil.test"));
        assertFalse(routes.needsResolution("example.net"));
    }

    @Test void matchesIpv4NetworkBoundariesAndHostBits() throws Exception {
        var routes = routes("192.168.5.77/23\n10.0.0.4/31\n");
        for (String host : new String[]{"192.168.4.0", "192.168.5.255", "10.0.0.4", "10.0.0.5"}) assertTrue(routes.matches(host), host);
        for (String host : new String[]{"192.168.3.255", "192.168.6.0", "10.0.0.3", "10.0.0.6"}) assertFalse(routes.matches(host), host);
        assertTrue(routes.needsResolution("internal.example"));
        assertFalse(routes.needsResolution("192.168.5.1"));
    }

    @Test void matchesIpv6NetworkBoundaries() throws Exception {
        var routes = routes("2001:db8:1234:5678:abcd::1/65\nfd00::/8\n");
        assertTrue(routes.matches("2001:db8:1234:5678:8000::"));
        assertTrue(routes.matches("2001:db8:1234:5678:ffff:ffff:ffff:ffff"));
        assertFalse(routes.matches("2001:db8:1234:5678:7fff:ffff:ffff:ffff"));
        assertFalse(routes.matches("2001:db8:1234:5679:8000::"));
        assertTrue(routes.matches("fd12::5"));
        assertFalse(routes.matches("fcff::5"));
        assertFalse(routes.matches("192.168.1.1"));
    }

    @Test void singleAddressesAreExactAndIpv6NotationIsNormalized() throws Exception {
        var routes = routes("127.0.0.1\n2001:db8::1/128\n");
        assertTrue(routes.matches("127.0.0.1"));
        assertFalse(routes.matches("127.0.0.2"));
        assertFalse(routes.matches("evil.127.0.0.1"));
        assertTrue(routes.matches("2001:0db8:0:0:0:0:0:1"));
        assertFalse(routes.matches("2001:db8::2"));
    }

    @Test void zeroPrefixesKeepAddressFamiliesSeparate() throws Exception {
        var ipv4 = routes("0.0.0.0/0");
        assertTrue(ipv4.matches("255.255.255.255"));
        assertFalse(ipv4.matches("::1"));
        var ipv6 = routes("::/0");
        assertTrue(ipv6.matches("::1"));
        assertFalse(ipv6.matches("127.0.0.1"));
    }

    @Test void invalidCidrFailsWithFileAndLine() {
        for (String rule : new String[]{"192.168.0.0/33", "::/129", "10.0.0.0/-1", "10.0.0.0/", "10.0.0.0/x", "example.com/24", "999.0.0.0/8", "::/64/2"}) {
            var error = assertThrows(IOException.class, () -> routes("# heading\n" + rule));
            assertTrue(error.getMessage().contains("pac.txt:2:"), error.getMessage());
        }
    }

    @Test void missingFileMeansProxyAll() throws Exception {
        var routes = new DirectRoutes(directory.resolve("missing.txt"));
        assertFalse(routes.matches("127.0.0.1"));
        assertFalse(routes.matches("localhost"));
        assertFalse(routes.needsResolution("localhost"));
    }
}
