package com.blacicada.proxy;

import com.blacicada.common.*;
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
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(30)
class UdpIntegrationTest {
    @TempDir Path directory;

    private String resource(String name) throws Exception { return Path.of(getClass().getResource("/tls/" + name).toURI()).toString(); }

    private final class Fixture implements AutoCloseable {
        final DatagramSocket origin = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0));
        final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
        final AutoCloseable server;
        final LocalProxyServer client;
        final KernelConfig config;
        final List<byte[]> received = new CopyOnWriteArrayList<>();
        final Set<SocketAddress> sources = ConcurrentHashMap.newKeySet();
        final List<Map<String, Object>> access = new CopyOnWriteArrayList<>();
        Fixture(String protocol, boolean direct, boolean wrongPassword) throws Exception {
            this(protocol, direct, wrongPassword, 0);
        }
        Fixture(String protocol, boolean direct, boolean wrongPassword, int interfaceIndex) throws Exception {
            origin.setSendBufferSize(128 * 1024);
            Properties values = new Properties();
            values.setProperty("bind", "127.0.0.1"); values.setProperty("port", "0");
            values.setProperty("password", "udp-test-secret");
            values.setProperty("tls.cert", resource("localhost.crt")); values.setProperty("tls.key", resource("localhost.key"));
            int port;
            if (protocol.equals("http2")) {
                var h2 = new Http2ProxyServer(new ProxyConfig(values, directory)).start(); server = h2; port = h2.address().getPort();
            } else {
                var h3 = new Http3ProxyServer(new ProxyConfig(values, directory)).start(); server = h3; port = h3.address().getPort();
            }
            Properties connection = new Properties();
            connection.setProperty("protocol", protocol); connection.setProperty("server.host", "127.0.0.1");
            connection.setProperty("server.port", "" + port); connection.setProperty("password", wrongPassword ? "wrong" : "udp-test-secret");
            connection.setProperty("tls.ca", resource("localhost.crt")); connection.setProperty("tls.serverName", "localhost");
            connection.setProperty("connectTimeoutMillis", "4000");
            Properties local = new Properties(); local.setProperty("port", "0"); local.setProperty("connectTimeoutMillis", "4000");
            if (direct) local.setProperty("routesInline", "127.0.0.1");
            config = new KernelConfig(new ProxyConfig(local, directory), List.of(
                    new KernelConfig.Profile("test", "UDP 测试节点", new ProxyConfig(connection, directory))), "test");
            client = new LocalProxyServer(config, null, access::add, interfaceIndex).start();
            workers.submit(() -> {
                while (!origin.isClosed()) try {
                    var packet = new DatagramPacket(new byte[65536], 65536);
                    origin.receive(packet);
                    received.add(Arrays.copyOf(packet.getData(), packet.getLength())); sources.add(packet.getSocketAddress());
                    origin.send(packet);
                } catch (IOException e) { if (!origin.isClosed()) throw new UncheckedIOException(e); }
            });
        }
        Socket socket() throws Exception {
            var socket = new Socket(); socket.connect(client.address()); socket.setSoTimeout(6000); return socket;
        }
        String request(String marker) {
            return request(marker, "127.0.0.1:" + origin.getLocalPort());
        }
        String request(String marker, String target) {
            return "CONNECT " + target + " HTTP/1.1\r\nHost: localhost\r\n"
                    + UdpTunnel.HEADER + ": " + marker + "\r\n\r\n";
        }
        Socket tunnel() throws Exception {
            var socket = socket();
            try { socket.getOutputStream().write(request("udp").getBytes(StandardCharsets.US_ASCII)); accepted(socket); return socket; }
            catch (Throwable e) { socket.close(); throw e; }
        }
        void rules(String rules) throws Exception {
            Properties local = config.local().values(); local.setProperty("routesInline", rules);
            client.apply(new KernelConfig(new ProxyConfig(local, directory), config.connections(), "test"));
        }
        @Override public void close() throws Exception {
            client.close(); server.close(); origin.close(); workers.shutdownNow(); workers.close();
        }
    }

    private static String headers(Socket socket) throws IOException {
        StringBuilder value = new StringBuilder(); int b;
        while ((b = socket.getInputStream().read()) >= 0) {
            value.append((char) b); if (value.toString().endsWith("\r\n\r\n")) return value.toString();
            if (value.length() > 32768) throw new IOException("响应头超过限制");
        }
        throw new EOFException(value.toString());
    }
    private static void accepted(Socket socket) throws IOException {
        String response = headers(socket);
        assertTrue(response.startsWith("HTTP/1.1 200"), response);
        assertTrue(response.toLowerCase(Locale.ROOT).contains(UdpTunnel.HEADER + ": udp\r\n"), response);
    }
    private static byte[] frame(byte[] packet) throws IOException {
        var bytes = new ByteArrayOutputStream(); var output = new DataOutputStream(bytes);
        output.writeShort(packet.length); output.write(packet); return bytes.toByteArray();
    }
    private static byte[] receive(Socket socket) throws IOException {
        var input = new DataInputStream(socket.getInputStream());
        byte[] result = new byte[input.readUnsignedShort()]; input.readFully(result); return result;
    }
    private static void echo(Socket socket, byte[] data) throws IOException {
        socket.getOutputStream().write(frame(data)); assertArrayEquals(data, receive(socket));
    }
    private static void await(BooleanSupplier predicate) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (!predicate.getAsBoolean() && System.nanoTime() < deadline) Thread.sleep(10);
        assertTrue(predicate.getAsBoolean());
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    @Timeout(60)
    void defaultCapacitySupportsMoreThan256UdpAssociations(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            var sockets = new ArrayList<Socket>();
            try {
                // 保持全部关联存活，验证实际握手与转发能够越过原先的 256 条上限。
                for (int i = 0; i < 300; i++) sockets.add(fixture.tunnel());
                for (int i = 0; i < sockets.size(); i++) {
                    try { echo(sockets.get(i), new byte[]{(byte) i}); }
                    catch (IOException failure) {
                        throw new AssertionError("并发 UDP 回显失败：协议=" + protocol + "，关联序号=" + i
                                + "，目标已接收报文=" + fixture.received.size(), failure);
                    }
                }
                assertEquals(300, fixture.client.tunnels().size());
                assertEquals(1, fixture.client.connectionCount());
                assertEquals("connected", fixture.client.connectionState());
                assertEquals("", fixture.client.lastError());
            } finally {
                for (var socket : sockets) socket.close();
            }
            await(() -> fixture.client.tunnels().isEmpty());
            try (var next = fixture.tunnel()) { echo(next, new byte[]{42}); }
            assertEquals(1, fixture.client.connectionCount(), "批量关闭隧道后应继续复用共享连接");
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void protectedMacosEgressSupportsBothTransportsAndDirectUdp(String protocol) throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        int index = NetworkInterface.getByName("lo0").getIndex();
        for (boolean direct : List.of(false, true)) try (var fixture = new Fixture(protocol, direct, false, index); var socket = fixture.tunnel()) {
            for (int size : List.of(0, 1, 4096, UdpFrameCodec.MAX_PAYLOAD)) {
                byte[] data = new byte[size]; new Random(size).nextBytes(data); echo(socket, data);
            }
            assertEquals(direct ? 0 : 1, fixture.client.connectionCount());
            var tunnel = fixture.client.tunnels().getFirst();
            assertEquals("udp", tunnel.get("originalProtocol"));
            assertEquals(direct ? "udp" : protocol, tunnel.get("protocol"));
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void packetsSurviveBothRoutesIncludingEmptyAndMaximumPayload(String protocol) throws Exception {
        for (boolean direct : List.of(false, true)) try (var fixture = new Fixture(protocol, direct, false); var socket = fixture.tunnel()) {
            long bytes = 0;
            for (int size : List.of(0, 1, 4096, UdpFrameCodec.MAX_PAYLOAD)) {
                byte[] data = new byte[size]; new Random(size).nextBytes(data);
                try { echo(socket, data); }
                catch (IOException e) { throw new AssertionError("UDP 回显失败：协议=" + protocol + "，直连=" + direct
                        + "，长度=" + size + "，目标已接收=" + fixture.received.stream().map(packet -> packet.length).toList(), e); }
                bytes += size;
            }
            assertEquals(4, fixture.received.size());
            long expected = bytes;
            await(() -> { fixture.client.traffic().sample(); var stats = fixture.client.traffic().snapshot(false);
                return stats.get("sentBytes").equals(expected) && stats.get("receivedBytes").equals(expected); });
            assertEquals(direct ? 0 : 1, fixture.client.connectionCount());
            assertTrue(fixture.access.stream().anyMatch(item -> item.get("method").equals("CONNECT-UDP") && item.get("state").equals("connected")));
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void fragmentedAndCoalescedDataIncludingFirstPacketBeforeHandshake(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false); var socket = fixture.socket()) {
            byte[] first = {1, 2, 3}, second = {4, 5}, third = {6};
            var combined = new ByteArrayOutputStream();
            combined.write(fixture.request("udp").getBytes(StandardCharsets.US_ASCII)); combined.write(frame(first)); combined.write(frame(second));
            socket.getOutputStream().write(combined.toByteArray()); accepted(socket);
            assertArrayEquals(first, receive(socket)); assertArrayEquals(second, receive(socket));
            byte[] split = frame(third);
            for (byte b : split) { socket.getOutputStream().write(b); Thread.sleep(20); }
            assertArrayEquals(third, receive(socket));
            assertEquals(3, fixture.received.size());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void concurrentAssociationsHaveSeparateUdpSourcesAndShareProxyConnection(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            try (var workers = Executors.newVirtualThreadPerTaskExecutor()) {
                var tasks = new ArrayList<Future<?>>();
                for (int i = 0; i < 8; i++) {
                    byte value = (byte) i;
                    tasks.add(workers.submit(() -> { try (var socket = fixture.tunnel()) {
                        for (int n = 0; n < 5; n++) echo(socket, new byte[]{value, (byte) n});
                    } return null; }));
                }
                for (var task : tasks) task.get(15, TimeUnit.SECONDS);
            }
            assertEquals(8, fixture.sources.size()); assertEquals(40, fixture.received.size());
            assertEquals(1, fixture.client.connectionCount());
            await(() -> fixture.client.activeTunnels() == 0 && fixture.client.tunnels().isEmpty());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void authenticationFailureDoesNotSendUdp(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, true); var socket = fixture.socket()) {
            socket.getOutputStream().write(fixture.request("udp").getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().write(frame(new byte[]{1}));
            assertTrue(headers(socket).startsWith("HTTP/1.1 502"));
            assertEquals(-1, socket.getInputStream().read()); assertTrue(fixture.received.isEmpty());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void malformedFramesCloseOnlyTheirAssociation(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            for (byte[] invalid : List.of(new byte[]{(byte) 255, (byte) 255}, new byte[]{0, 2, 1})) {
                try (var socket = fixture.tunnel()) {
                    socket.getOutputStream().write(invalid); socket.shutdownOutput();
                    assertEquals(-1, socket.getInputStream().read());
                }
            }
            assertTrue(fixture.received.isEmpty());
            try (var good = fixture.tunnel()) { echo(good, new byte[]{9}); }
            assertEquals(1, fixture.client.connectionCount());
            await(() -> fixture.client.activeTunnels() == 0);
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void routeChangesAndDisconnectCloseUdpAssociations(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            try (var proxied = fixture.tunnel()) {
                echo(proxied, new byte[]{1}); fixture.rules("127.0.0.1");
                assertEquals(-1, proxied.getInputStream().read());
            }
            try (var direct = fixture.tunnel()) {
                echo(direct, new byte[]{2}); fixture.rules(""); assertEquals(-1, direct.getInputStream().read());
            }
            try (var proxied = fixture.tunnel()) {
                echo(proxied, new byte[]{3}); fixture.client.disconnect(); assertEquals(-1, proxied.getInputStream().read());
            }
            await(() -> fixture.client.activeTunnels() == 0 && fixture.client.tunnels().isEmpty());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void serverRejectsMalformedPacketsEvenWhenLocalEntryIsBypassed(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            var loop = new io.netty.channel.nio.NioEventLoopGroup(1);
            var resolver = Transport.resolver();
            try (var session = ProxySessionFactory.create(loop.next(), fixture.config.profile("test").config(), resolver)) {
                for (byte[] invalid : List.of(new byte[]{(byte) 255, (byte) 255}, new byte[]{0, 2, 1})) {
                    var opening = session.open(new Authority("127.0.0.1", fixture.origin.getLocalPort()), true);
                    assertTrue(opening.await(5000)); assertTrue(opening.isSuccess(), () -> String.valueOf(opening.cause()));
                    var channel = opening.getNow();
                    var ended = new CompletableFuture<Void>();
                    channel.pipeline().addLast(new io.netty.channel.ChannelInboundHandlerAdapter() {
                        @Override public void channelInactive(io.netty.channel.ChannelHandlerContext ctx) { ended.complete(null); }
                        @Override public void userEventTriggered(io.netty.channel.ChannelHandlerContext ctx, Object event) {
                            if (event == io.netty.channel.socket.ChannelInputShutdownEvent.INSTANCE) { ended.complete(null); ctx.close(); }
                            else ctx.fireUserEventTriggered(event);
                        }
                        @Override public void exceptionCaught(io.netty.channel.ChannelHandlerContext ctx, Throwable cause) {
                            if (cause instanceof io.netty.handler.codec.quic.QuicStreamResetException) ended.complete(null);
                            else ended.completeExceptionally(cause);
                            ctx.close();
                        }
                    });
                    channel.writeAndFlush(io.netty.buffer.Unpooled.wrappedBuffer(invalid)).sync();
                    Transport.shutdownOutput(channel); channel.read();
                    ended.get(5, TimeUnit.SECONDS);
                    channel.close().sync();
                }
                assertTrue(fixture.received.isEmpty()); assertEquals(1, session.connectionCount());
            } finally { resolver.close(); loop.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync(); }
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void ipv6AndDomainTargetsWork(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            try (var socket = fixture.socket()) {
                socket.getOutputStream().write(fixture.request("udp", "localhost:" + fixture.origin.getLocalPort()).getBytes(StandardCharsets.US_ASCII));
                accepted(socket); echo(socket, new byte[]{7});
            }
            try (var ipv6 = new DatagramSocket(new InetSocketAddress("::1", 0)); var socket = fixture.socket()) {
                ipv6.setSoTimeout(5000);
                socket.getOutputStream().write(fixture.request("udp", "[::1]:" + ipv6.getLocalPort()).getBytes(StandardCharsets.US_ASCII));
                accepted(socket); socket.getOutputStream().write(frame(new byte[]{8}));
                var packet = new DatagramPacket(new byte[10], 10); ipv6.receive(packet); ipv6.send(packet);
                assertArrayEquals(new byte[]{8}, receive(socket));
            }
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void eofBeforeHandshakeDoesNotLeaveAssociationOpen(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false); var socket = fixture.socket()) {
            socket.getOutputStream().write(fixture.request("udp").getBytes(StandardCharsets.US_ASCII));
            socket.shutdownOutput();
            socket.getInputStream().readAllBytes();
            await(() -> fixture.client.activeTunnels() == 0 && fixture.client.tunnels().isEmpty());
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void associationAcceptsMultipleRepliesButRejectsOtherSources(String protocol) throws Exception {
        for (boolean direct : List.of(false, true)) try (var fixture = new Fixture(protocol, direct, false);
                var socket = fixture.tunnel(); var stranger = new DatagramSocket()) {
            echo(socket, new byte[]{1});
            SocketAddress destination = fixture.sources.iterator().next();
            stranger.send(new DatagramPacket(new byte[]{88}, 1, destination));
            fixture.origin.send(new DatagramPacket(new byte[]{77}, 1, destination));
            assertArrayEquals(new byte[]{77}, receive(socket));
            echo(socket, new byte[]{2});
        }
    }

    @ParameterizedTest @ValueSource(strings = {"http2", "http3"})
    void localEntryRejectsUnknownOrRepeatedTransportMarker(String protocol) throws Exception {
        try (var fixture = new Fixture(protocol, false, false)) {
            for (String marker : List.of("unknown", "udp\r\n" + UdpTunnel.HEADER + ": udp")) {
                try (var socket = fixture.socket()) {
                    socket.getOutputStream().write(fixture.request(marker).getBytes(StandardCharsets.US_ASCII));
                    assertTrue(headers(socket).startsWith("HTTP/1.1 400"));
                }
            }
            assertEquals(0, fixture.client.connectionCount()); assertTrue(fixture.received.isEmpty());
        }
    }
}
