package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.common.OutboundNetwork;
import com.blacicada.config.KernelConfig;
import com.blacicada.control.ControlEvents;
import com.blacicada.control.ControlLogs;
import io.netty.resolver.dns.DnsServerAddresses;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(20)
class KernelDnsTest {
    static String awaitLog(ControlEvents events, String logger, String text) throws Exception {
        long cursor = 0, deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (System.nanoTime() < deadline) {
            var batch = events.await(cursor, 100);
            cursor = batch.cursor();
            for (var event : batch.events()) if (event.data() instanceof Map<?, ?> entry
                    && logger.equals(entry.get("logger")) && entry.get("message").toString().contains(text))
                return entry.get("message").toString();
        }
        fail("未收到预期日志：" + text); return "";
    }
    static byte[] query(String name, int type, int id) throws IOException {
        var bytes = new ByteArrayOutputStream(); var out = new DataOutputStream(bytes);
        out.writeShort(id); out.writeShort(0x0100); out.writeShort(1);
        out.writeShort(0); out.writeShort(0); out.writeShort(0);
        for (String label : name.isEmpty() ? new String[0] : name.split("\\.")) { out.writeByte(label.length()); out.writeBytes(label); }
        out.writeByte(0); out.writeShort(type); out.writeShort(1); return bytes.toByteArray();
    }
    static byte[] answer(byte[] query, String ip, int ttl) throws Exception {
        var bytes = new ByteArrayOutputStream(); bytes.write(query);
        var out = new DataOutputStream(bytes); out.writeShort(0xc00c);
        out.writeShort(ip.contains(":") ? 28 : 1); out.writeShort(1); out.writeInt(ttl);
        byte[] address = InetAddress.getByName(ip).getAddress(); out.writeShort(address.length); out.write(address);
        byte[] response = bytes.toByteArray(); response[2] = (byte) 0x81; response[3] = (byte) 0x80;
        response[7] = 1; return response;
    }
    static byte[] frame(byte[] bytes) throws IOException {
        var output = new ByteArrayOutputStream(); var data = new DataOutputStream(output);
        data.writeShort(bytes.length); data.write(bytes); return output.toByteArray();
    }
    static byte[] receive(Socket socket) throws IOException {
        var in = new DataInputStream(socket.getInputStream()); byte[] bytes = new byte[in.readUnsignedShort()]; in.readFully(bytes); return bytes;
    }
    static String headers(Socket socket) throws IOException {
        var output = new StringBuilder();
        while (!output.toString().endsWith("\r\n\r\n")) {
            int b = socket.getInputStream().read(); if (b < 0) throw new EOFException("握手提前结束"); output.append((char) b);
        }
        return output.toString();
    }

    /** 本机双协议 DNS 上游，不依赖系统 DNS 或外部网络，也不占用 53 端口。 */
    static final class Upstream implements AutoCloseable {
        final ServerSocket tcp;
        final DatagramSocket udp;
        final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
        final List<byte[]> requests = new CopyOnWriteArrayList<>();
        volatile String ip = "127.0.0.1";
        volatile int ttl = 60;
        volatile int delayMillis;
        volatile boolean truncated, wrongFirst;
        Upstream() throws Exception {
            ServerSocket boundTcp = null;
            DatagramSocket boundUdp = null;
            for (int attempt = 0; attempt < 16; attempt++) {
                var candidate = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
                try {
                    boundUdp = new DatagramSocket(candidate.getLocalSocketAddress());
                    boundTcp = candidate;
                    break;
                } catch (BindException occupied) {
                    // TCP 分配的空闲端口可能已被 UDP 占用，释放后重新选择双协议可用端口。
                    candidate.close();
                    if (attempt == 15) throw occupied;
                } catch (Exception failure) {
                    candidate.close();
                    throw failure;
                }
            }
            tcp = boundTcp;
            udp = boundUdp;
            workers.submit(() -> {
                while (!udp.isClosed()) try {
                    var packet = new DatagramPacket(new byte[65536], 65536); udp.receive(packet);
                    byte[] query = Arrays.copyOf(packet.getData(), packet.getLength()); requests.add(query);
                    byte[] reply = reply(query);
                    if (wrongFirst) {
                        byte[] bad = reply.clone(); bad[0] ^= 1;
                        udp.send(new DatagramPacket(bad, bad.length, packet.getSocketAddress()));
                    }
                    udp.send(new DatagramPacket(reply, reply.length, packet.getSocketAddress()));
                } catch (Exception e) { if (!udp.isClosed()) throw new RuntimeException(e); }
            });
            workers.submit(() -> {
                while (!tcp.isClosed()) try {
                    Socket socket = tcp.accept(); socket.setSoTimeout(3000);
                    workers.submit(() -> {
                        try (socket) {
                            byte[] query = receive(socket); requests.add(query);
                            socket.getOutputStream().write(frame(reply(query)));
                        } catch (Exception e) { if (!tcp.isClosed()) throw new RuntimeException(e); }
                    });
                } catch (IOException e) { if (!tcp.isClosed()) throw new UncheckedIOException(e); }
            });
        }
        byte[] reply(byte[] query) throws Exception {
            if (delayMillis > 0) Thread.sleep(delayMillis);
            byte[] result = answer(query, ip, ttl);
            if (truncated) { result[2] |= 2; result = Arrays.copyOf(result, query.length); }
            return result;
        }
        InetSocketAddress address() { return (InetSocketAddress) tcp.getLocalSocketAddress(); }
        @Override public void close() throws Exception { tcp.close(); udp.close(); workers.shutdownNow(); workers.close(); }
    }
    static LocalProxyServer client(Upstream server) throws Exception { return client(server, 0); }
    static LocalProxyServer client(Upstream server, int interfaceIndex) throws Exception {
        Properties values = new Properties(); values.setProperty("port", "0"); values.setProperty("routingMode", "direct");
        var config = new KernelConfig(new ProxyConfig(values, Path.of(".")), List.of(), "");
        return new LocalProxyServer(config, null, null, interfaceIndex,
                name -> DnsServerAddresses.singleton(server.address()).stream()).start();
    }
    static Socket connect(LocalProxyServer client, String target, boolean udp, byte[] early) throws Exception {
        Socket socket = new Socket(); socket.connect(client.address()); socket.setSoTimeout(5000);
        String request = "CONNECT " + target + " HTTP/1.1\r\nHost: " + target + "\r\nX-Network-Source: tun\r\n"
                + (udp ? "X-Network-Transport: udp\r\n" : "") + "\r\n";
        var combined = new ByteArrayOutputStream(); combined.write(request.getBytes(StandardCharsets.US_ASCII)); combined.write(early);
        socket.getOutputStream().write(combined.toByteArray());
        assertTrue(headers(socket).startsWith("HTTP/1.1 200")); return socket;
    }

    @ParameterizedTest @ValueSource(booleans = {true, false})
    void interceptsDnsAndPreservesIdsCacheAndFraming(boolean udp) throws Exception {
        try (var server = new Upstream(); var client = client(server)) {
            byte[] first = query("first.example", 1, 42), second = query("second.example", 1, 42);
            var early = new ByteArrayOutputStream(); early.write(frame(first)); early.write(frame(second));
            try (Socket socket = connect(client, "198.51.100.53:53", udp, early.toByteArray())) {
                var replies = List.of(new DnsMessage(receive(socket), true), new DnsMessage(receive(socket), true));
                assertEquals(Set.of("first.example", "second.example"), new HashSet<>(replies.stream().map(r -> r.question.name()).toList()));
                for (var reply : replies) { assertEquals(42, reply.id); assertEquals(Map.of("127.0.0.1", 60L), reply.addresses()); }
                byte[] cached = frame(query("first.example", 1, 77));
                for (byte b : cached) socket.getOutputStream().write(new byte[]{b});
                assertEquals(77, new DnsMessage(receive(socket), true).id);
                assertEquals(2, server.requests.size(), "缓存命中不应再查询上游");
                socket.getOutputStream().write(frame(new byte[]{0, 1}));
                byte[] malformed = receive(socket); assertEquals(1, malformed[3] & 15);
                socket.getOutputStream().write(frame(query("first.example", 1, 78)));
                assertEquals(78, new DnsMessage(receive(socket), true).id);
            }
        }
    }

    @ParameterizedTest @ValueSource(booleans = {true, false})
    void latestDomainAppearsOnConnectionsWithoutChangingDestination(boolean udp) throws Exception {
        try (var server = new Upstream(); var client = client(server);
             var origin = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
             var dns = connect(client, "203.0.113.53:53", udp, new byte[0])) {
            for (String domain : List.of("first.example", "latest.example")) {
                dns.getOutputStream().write(frame(query(domain, 1, 10))); receive(dns);
            }
            try (var business = connect(client, "127.0.0.1:" + origin.getLocalPort(), false, new byte[0]);
                 var accepted = origin.accept()) {
                assertTrue(client.tunnels().stream().anyMatch(t -> t.get("target").equals("latest.example:" + origin.getLocalPort())));
                business.getOutputStream().write(123); assertEquals(123, accepted.getInputStream().read());
            }
        }
    }

    @Test void ipv6TruncationAndMismatchedReplyAreHandled() throws Exception {
        try (var server = new Upstream(); var client = client(server);
             var socket = connect(client, "[2001:db8::53]:53", true, new byte[0])) {
            server.ip = "2001:db8::8"; server.wrongFirst = true;
            socket.getOutputStream().write(frame(query("ipv6.example", 28, 20)));
            assertTrue(new DnsMessage(receive(socket), true).addresses().containsKey(InetAddress.getByName(server.ip).getHostAddress()));
            server.truncated = true;
            socket.getOutputStream().write(frame(query("truncated.example", 1, 21)));
            var reply = new DnsMessage(receive(socket), true); assertEquals(21, reply.id); assertEquals(0x200, reply.flags & 0x200);
            assertTrue(reply.addresses().isEmpty(), "截断回答不能更新域名关联");
        }
    }

    @Test void expiresAndReplacesAssociationsIncludingCnameChain() throws Exception {
        var now = new AtomicLong(); var resolver = OutboundNetwork.DEFAULT.resolver();
        try {
            var dns = new KernelDns(OutboundNetwork.DEFAULT, resolver, name -> DnsServerAddresses.singleton(new InetSocketAddress("127.0.0.1", 53)).stream(), 100, now::get);
            dns.remember(new DnsMessage(answer(query("first.example", 1, 1), "192.0.2.1", 10), true));
            dns.remember(new DnsMessage(answer(query("latest.example", 1, 1), "192.0.2.1", 2), true));
            assertEquals("latest.example", dns.domain("192.0.2.1"));
            now.set(TimeUnit.SECONDS.toNanos(2)); assertNull(dns.domain("192.0.2.1"));
            dns.remember(new DnsMessage(answer(query("zero.example", 1, 1), "192.0.2.1", 0), true));
            assertNull(dns.domain("192.0.2.1"));
            byte[] query = query("alias.example", 1, 1);
            var bytes = new ByteArrayOutputStream(); bytes.write(query); var out = new DataOutputStream(bytes);
            out.writeShort(0xc00c); out.writeShort(5); out.writeShort(1); out.writeInt(3);
            out.writeShort(8); int aliasOffset = bytes.size(); out.writeByte(6); out.writeBytes("target"); out.writeByte(0);
            out.writeShort(0xc000 | aliasOffset); out.writeShort(1); out.writeShort(1); out.writeInt(30); out.writeShort(4); out.write(new byte[]{(byte) 192, 0, 2, 2});
            byte[] response = bytes.toByteArray(); response[2] = (byte) 0x81; response[3] = (byte) 0x80; response[7] = 2;
            dns.remember(new DnsMessage(response, true)); assertEquals("alias.example", dns.domain("192.0.2.2"));
            now.addAndGet(TimeUnit.SECONDS.toNanos(3)); assertNull(dns.domain("192.0.2.2"));
            byte[] unrelated = answer(query("safe.example", 1, 1), "192.0.2.3", 30);
            unrelated[7] = 0; unrelated[11] = 1;
            dns.remember(new DnsMessage(unrelated, true)); assertNull(dns.domain("192.0.2.3"));
        } finally { resolver.close(); }
    }

    @Test void macosDnsUsesProtectedOutboundSockets() throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        int index = NetworkInterface.getByName("lo0").getIndex();
        try (var server = new Upstream(); var client = client(server, index)) {
            for (boolean udp : List.of(true, false)) try (var socket = connect(client, "198.51.100.53:53", udp, new byte[0])) {
                socket.getOutputStream().write(frame(query("protected.example", 1, 90)));
                assertEquals(90, new DnsMessage(receive(socket), true).id);
            }
            assertEquals(2, server.requests.size());
        }
    }

    @Test void responseCacheExpiresAndDoesNotExtendAssociationTtl() throws Exception {
        var network = OutboundNetwork.DEFAULT; var group = network.newGroup(); var resolver = network.resolver();
        var now = new AtomicLong();
        try (var server = new Upstream()) {
            var loop = group.next(); server.ttl = 2;
            var dns = new KernelDns(network, resolver, name -> DnsServerAddresses.singleton(server.address()).stream(), 1000, now::get);
            var first = loop.submit(() -> dns.query(loop, query("cache.example", 1, 1), true)).sync().getNow(); first.sync();
            now.set(TimeUnit.SECONDS.toNanos(1));
            var cached = loop.submit(() -> dns.query(loop, query("cache.example", 1, 2), true)).sync().getNow();
            assertEquals(1L, new DnsMessage(cached.sync().getNow(), true).addresses().get("127.0.0.1").longValue());
            assertEquals(1, server.requests.size());
            now.set(TimeUnit.SECONDS.toNanos(2));
            assertNull(loop.submit(() -> dns.domain("127.0.0.1")).sync().getNow());
            var fresh = loop.submit(() -> dns.query(loop, query("cache.example", 1, 3), true)).sync().getNow(); fresh.sync();
            assertEquals(2, server.requests.size());
        } finally { resolver.close(); group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync(); }
    }

    @ParameterizedTest @ValueSource(booleans = {true, false})
    void nonDnsTargetsPassThroughWithoutInterpretation(boolean udp) throws Exception {
        // DNS 格式的负载发往非 53 端口也必须普通转发，不能因此建立域名关联。
        try (var server = new Upstream(); var client = client(server);
             var socket = connect(client, "127.0.0.1:" + server.address().getPort(), udp, new byte[0])) {
            assertEquals("127.0.0.1:" + server.address().getPort(), client.tunnels().getFirst().get("target"));
            byte[] query = query("not-intercepted.example", 1, 123);
            socket.getOutputStream().write(frame(query)); assertEquals(123, new DnsMessage(receive(socket), true).id);
            assertArrayEquals(query, server.requests.getFirst());
            try (var next = connect(client, "127.0.0.1:" + server.address().getPort(), udp, new byte[0])) {
                assertTrue(client.tunnels().stream().allMatch(t -> t.get("target").equals("127.0.0.1:" + server.address().getPort())));
            }
        }
    }

    @Test void tcpHalfCloseStillReturnsPendingDnsAnswer() throws Exception {
        try (var server = new Upstream(); var client = client(server);
             var socket = connect(client, "198.51.100.53:53", false, new byte[0])) {
            socket.getOutputStream().write(frame(query("half-close.example", 1, 99))); socket.shutdownOutput();
            assertEquals(99, new DnsMessage(receive(socket), true).id);
            assertEquals(-1, socket.getInputStream().read());
        }
    }

    @Test void retriesSystemServersTimesOutAndCancels() throws Exception {
        var network = OutboundNetwork.DEFAULT; var group = network.newGroup(); var resolver = network.resolver();
        try (var events = new ControlEvents(); var logs = new ControlLogs(events, text -> text);
             var silent = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0)); var server = new Upstream()) {
            var loop = group.next();
            var dns = new KernelDns(network, resolver, name -> DnsServerAddresses.sequential(
                    (InetSocketAddress) silent.getLocalSocketAddress(), server.address()).stream(), 100, System::nanoTime);
            var promise = loop.submit(() -> dns.query(loop, query("retry.example", 1, 22), true)).sync().getNow();
            assertEquals(22, new DnsMessage(promise.sync().getNow(), true).id);
            var unavailable = new KernelDns(network, resolver, name -> DnsServerAddresses.singleton(
                    (InetSocketAddress) silent.getLocalSocketAddress()).stream(), 100, System::nanoTime);
            var failed = loop.submit(() -> unavailable.query(loop, query("timeout.example", 1, 23), true)).sync().getNow();
            assertEquals(2, failed.sync().getNow()[3] & 15);
            String message = awaitLog(events, KernelDns.class.getName(), "域名=timeout.example");
            assertTrue(message.contains("上游=" + silent.getLocalSocketAddress()));
            assertTrue(message.contains("超时（100 毫秒）"));
            var cancelled = loop.submit(() -> unavailable.query(loop, query("cancel.example", 1, 24), true)).sync().getNow();
            cancelled.cancel(false); assertTrue(cancelled.isCancelled());
        } finally { resolver.close(); group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync(); }
    }
}
