package com.blacicada.common;

import io.netty.resolver.dns.DnsServerAddresses;
import java.net.InetSocketAddress;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class DnsTunnelTest {
    @Test void validatesMarkerAndUsesOnlyServerProvidedAddresses() {
        var first = new InetSocketAddress("127.0.0.1", 1053);
        var second = new InetSocketAddress("127.0.0.1", 2053);
        var name = new AtomicReference<String>();
        for (String query : List.of("example.com", "_service._tcp.example", "")) {
            var request = new DnsTunnel(query, 1);
            assertTrue(request.confirmed(List.of(request.header())));
            assertFalse(request.confirmed(List.of()));
            assertFalse(request.confirmed(List.of("system")));
            assertFalse(request.confirmed(List.of(request.header(), request.header())));
            assertFalse(request.confirmed(List.of(new DnsTunnel(query, 0).header())));
            assertEquals(request, DnsTunnel.requested(List.of(request.header()), DnsTunnel.TARGET));
            assertEquals(second, request.upstream(domain -> {
                name.set(domain); return DnsServerAddresses.sequential(first, first, second).stream();
            }));
            assertEquals(query, name.get());
        }
        assertNull(DnsTunnel.requested(List.of(), new Authority("example.com", 443)));
        var valid = new DnsTunnel("example.com", 0).header();
        assertThrows(IllegalArgumentException.class, () -> DnsTunnel.requested(List.of(valid, valid), DnsTunnel.TARGET));
        assertThrows(IllegalArgumentException.class, () -> DnsTunnel.requested(List.of(valid), new Authority("example.com", 53)));
        for (String invalid : List.of("system", "-1:", "4:", "0:!", "00:", "0:YQ==", "0:a:b"))
            assertThrows(IllegalArgumentException.class, () -> DnsTunnel.requested(List.of(invalid), DnsTunnel.TARGET));
        assertThrows(IllegalStateException.class, () -> new DnsTunnel("example.com", 1)
                .upstream(domain -> DnsServerAddresses.singleton(first).stream()));
        assertThrows(IllegalArgumentException.class, () -> new DnsTunnel("a".repeat(254), 0));
    }
}
