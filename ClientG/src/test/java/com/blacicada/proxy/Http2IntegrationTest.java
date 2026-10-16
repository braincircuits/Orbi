package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.common.ProxyCredentials;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.util.ReferenceCountUtil;
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
class Http2IntegrationTest {
    @TempDir
    Path directory;
    private com.blacicada.h2.Http2ProxyServer server;
    private LocalProxyServer client;
    private Origin echo;

    @BeforeEach
    void start() throws Exception {
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
        options.setProperty("bind", "127.0.0.1");
        options.setProperty("port", "0");
        options.setProperty("tls.cert", resource("localhost.crt"));
        options.setProperty("tls.key", resource("localhost.key"));
        options.setProperty("connectTimeoutMillis", "3000");
        server = new com.blacicada.h2.Http2ProxyServer(new ProxyConfig(options, directory)).start();
        client = proxy(clientConfig("integration-test-secret", "localhost", false, 32)).start();
    }

    private LocalProxyServer proxy(ProxyConfig options) {
        return new LocalProxyServer(TestKernelConfig.from(options));
    }

    private String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }

    private ProxyConfig clientConfig(String password, String name, boolean direct, int streams) throws Exception {
        var options = new Properties();
        options.setProperty("protocol", "http2");
        options.setProperty("password", password);
        options.setProperty("port", "0");
        options.setProperty("server.host", "127.0.0.1");
        options.setProperty("server.port", Integer.toString(server.address().getPort()));
        options.setProperty("tls.ca", resource("localhost.crt"));
        options.setProperty("tls.serverName", name);
        options.setProperty("connectTimeoutMillis", "3000");
        options.setProperty("maxStreams", Integer.toString(streams));
        if (direct) {
            options.setProperty("routesInline", "# 注释\n\n127.0.0.1\n");
        }
        return new ProxyConfig(options, directory);
    }

    @AfterEach
    void stop() throws Exception {
        if (client != null) client.close();
        if (server != null) server.close();
        if (echo != null) echo.close();
    }

    private Socket socket(LocalProxyServer proxy) throws Exception {
        Socket s = new Socket();
        s.connect(proxy.address());
        s.setSoTimeout(12000);
        return s;
    }

    private Socket tunnel(LocalProxyServer proxy, int targetPort) throws Exception {
        Socket s = socket(proxy);
        send(s, "CONNECT localhost:" + targetPort + " HTTP/1.1\r\nHost: localhost:" + targetPort + "\r\n\r\n");
        String response = headers(s.getInputStream());
        if (!response.startsWith("HTTP/1.1 200")) {
            s.close();
            fail(response);
        }
        return s;
    }

    private static void send(Socket s, String text) throws IOException {
        s.getOutputStream().write(text.getBytes(StandardCharsets.US_ASCII));
        s.getOutputStream().flush();
    }

    private static String headers(InputStream input) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int state = 0, b;
        byte[] ending = {'\r', '\n', '\r', '\n'};
        while ((b = input.read()) != -1) {
            out.write(b);
            state = b == ending[state] ? state + 1 : (b == '\r' ? 1 : 0);
            if (state == 4) return out.toString(StandardCharsets.US_ASCII);
            if (out.size() > 32768) throw new IOException("请求头超过大小限制");
        }
        throw new EOFException(out.toString(StandardCharsets.US_ASCII));
    }

    @Test
    void unknownFramesDoNotCloseEstablishedTunnel() throws Exception {
        var group = new NioEventLoopGroup(1);
        Channel connection = null;
        var settings = new CompletableFuture<Void>();
        var status = new CompletableFuture<String>();
        var received = new CompletableFuture<byte[]>();
        byte[] payload = "unknown-frame-payload".getBytes(StandardCharsets.US_ASCII);
        try {
            var config = clientConfig("integration-test-secret", "localhost", false, 8);
            var ssl = SslContextBuilder.forClient().trustManager(new File(resource("localhost.crt")))
                    .applicationProtocolConfig(new ApplicationProtocolConfig(ApplicationProtocolConfig.Protocol.ALPN,
                            ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                            ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2")).build();
            connection = new Bootstrap().group(group).channel(NioSocketChannel.class)
                    .handler(new ChannelInitializer<Channel>() {
                        @Override
                        protected void initChannel(Channel channel) {
                            channel.pipeline().addLast(ssl.newHandler(channel.alloc(), "localhost", server.address().getPort()));
                            channel.pipeline().addLast(Http2FrameCodecBuilder.forClient().build());
                            channel.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                @Override
                                public void channelRead(ChannelHandlerContext ctx, Object message) {
                                    if (message instanceof Http2SettingsFrame) settings.complete(null);
                                    ctx.fireChannelRead(message);
                                }
                            });
                            channel.pipeline().addLast(new Http2MultiplexHandler(new ChannelInboundHandlerAdapter()));
                        }
                    }).connect(server.address()).sync().channel();
            settings.get(5, TimeUnit.SECONDS);
            var stream = new Http2StreamChannelBootstrap(connection).handler(new ChannelInboundHandlerAdapter() {
                private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();

                @Override
                public void channelRead(ChannelHandlerContext ctx, Object message) {
                    try {
                        if (message instanceof Http2HeadersFrame headers)
                            status.complete(headers.headers().status().toString());
                        else if (message instanceof Http2DataFrame frame) {
                            byte[] part = new byte[frame.content().readableBytes()];
                            frame.content().readBytes(part);
                            bytes.writeBytes(part);
                            if (bytes.size() >= payload.length) received.complete(bytes.toByteArray());
                        }
                    } finally {
                        ReferenceCountUtil.release(message);
                    }
                }

                @Override
                public void channelInactive(ChannelHandlerContext ctx) {
                    received.completeExceptionally(new EOFException("收到业务数据前隧道已关闭"));
                }

                @Override
                public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
                    status.completeExceptionally(cause);
                    received.completeExceptionally(cause);
                    ctx.close();
                }
            }).open().sync().getNow();
            var request = new DefaultHttp2Headers().method("CONNECT").authority("127.0.0.1:" + echo.port())
                    .set("proxy-authorization", ProxyCredentials.clientAuthorization(config));
            stream.writeAndFlush(new DefaultHttp2HeadersFrame(request)).sync();
            assertEquals("200", status.get(5, TimeUnit.SECONDS));
            stream.writeAndFlush(new DefaultHttp2UnknownFrame((byte) 0x40, new Http2Flags(), Unpooled.buffer(1).writeByte(99))).sync();
            stream.writeAndFlush(new DefaultHttp2DataFrame(Unpooled.wrappedBuffer(payload))).sync();
            assertArrayEquals(payload, received.get(5, TimeUnit.SECONDS));
            assertTrue(stream.isActive(), "忽略未知帧后业务隧道应保持可用");
            stream.close().sync();
        } finally {
            if (connection != null) connection.close().syncUninterruptibly();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }

    @Test
    void unknownFramesBeforeConnectResponseDoNotFailNewTunnel() throws Exception {
        try (Socket active = tunnel(client, echo.port())) {
            var field = server.getClass().getDeclaredField("connections");
            field.setAccessible(true);
            var connections = (io.netty.channel.group.ChannelGroup) field.get(server);
            Channel parent = connections.iterator().next();
            parent.eventLoop().submit(() -> {
                String multiplex = parent.pipeline().context(Http2MultiplexHandler.class).name();
                parent.pipeline().addBefore(multiplex, "unknownBeforeResponse", new ChannelOutboundHandlerAdapter() {
                    @Override
                    public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) {
                        if (message instanceof Http2HeadersFrame headers && "200".contentEquals(headers.headers().status())) {
                            ctx.write(new DefaultHttp2UnknownFrame((byte) 0x40, new Http2Flags(),
                                    Unpooled.buffer(1).writeByte(99)).stream(headers.stream()));
                        }
                        ctx.write(message, promise);
                    }
                });
            }).sync();
            try (Socket next = tunnel(client, echo.port())) {
                send(next, "ok");
                assertEquals("ok", new String(next.getInputStream().readNBytes(2), StandardCharsets.US_ASCII));
                send(active, "x");
                assertEquals('x', active.getInputStream().read());
            }
            assertEquals(1, client.connectionCount(), "未知扩展帧不能破坏 CONNECT 或触发重连");
        }
    }

    @Test
    void concurrentTunnelsShareOneConnection() throws Exception {
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var tasks = new ArrayList<java.util.concurrent.Future<?>>();
            for (int i = 0; i < 12; i++) {
                final int value = i;
                tasks.add(executor.submit(() -> {
                    try (Socket s = tunnel(client, echo.port())) {
                        byte[] data = new byte[32768];
                        Arrays.fill(data, (byte) value);
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

    @Test
    void fragmentedHeadersAndCoalescedTunnelData() throws Exception {
        try (Socket s = socket(client)) {
            send(s, "CON");
            Thread.sleep(30);
            send(s, "NECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r");
            Thread.sleep(30);
            send(s, "\ncoalesced-payload");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("coalesced-payload", new String(s.getInputStream().readNBytes(17), StandardCharsets.US_ASCII));
        }
    }

    @Test
    void largeTransferAndHalfClose() throws Exception {
        byte[] data = new byte[4 * 1024 * 1024];
        new Random(7).nextBytes(data);
        try (Socket s = tunnel(client, echo.port()); var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var writer = executor.submit(() -> {
                s.getOutputStream().write(data);
                s.shutdownOutput();
                return null;
            });
            assertArrayEquals(data, s.getInputStream().readAllBytes());
            writer.get(20, TimeUnit.SECONDS);
        }
    }

    @Test
    void connectWithEarlyDataReturnsPayloadWithoutFurtherClientWrites() throws Exception {
        var group = new NioEventLoopGroup(1);
        Channel connection = null;
        byte[] payload = new byte[48 * 1024];
        new Random(29).nextBytes(payload);
        var status = new CompletableFuture<String>();
        var received = new CompletableFuture<byte[]>();
        try {
            var ssl = SslContextBuilder.forClient().sslProvider(SslProvider.JDK)
                    .trustManager(new File(resource("localhost.crt")))
                    .applicationProtocolConfig(new ApplicationProtocolConfig(ApplicationProtocolConfig.Protocol.ALPN,
                            ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                            ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2")).build();
            connection = new Bootstrap().group(group).channel(NioSocketChannel.class)
                    .handler(new ChannelInitializer<SocketChannel>() {
                        @Override
                        protected void initChannel(SocketChannel channel) {
                            channel.pipeline().addLast(ssl.newHandler(channel.alloc(), "localhost", server.address().getPort()));
                            channel.pipeline().addLast(Http2FrameCodecBuilder.forClient().build());
                            channel.pipeline().addLast(new Http2MultiplexHandler(new ChannelInboundHandlerAdapter()));
                        }
                    }).connect(server.address()).sync().channel();
            connection.pipeline().get(SslHandler.class).handshakeFuture().sync();
            var stream = new Http2StreamChannelBootstrap(connection).handler(new ChannelInboundHandlerAdapter() {
                private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();

                @Override
                public void channelRead(ChannelHandlerContext ctx, Object message) {
                    try {
                        if (message instanceof Http2HeadersFrame headers)
                            status.complete(headers.headers().status().toString());
                        else if (message instanceof Http2DataFrame frame) {
                            byte[] part = new byte[frame.content().readableBytes()];
                            frame.content().readBytes(part);
                            bytes.writeBytes(part);
                            if (bytes.size() >= payload.length) received.complete(bytes.toByteArray());
                        }
                    } finally {
                        ReferenceCountUtil.release(message);
                    }
                }

                @Override
                public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
                    status.completeExceptionally(cause);
                    received.completeExceptionally(cause);
                    ctx.close();
                }
            }).open().sync().getNow();
            var request = new DefaultHttp2Headers().method("CONNECT").authority("localhost:" + echo.port())
                    .set("proxy-authorization", ProxyCredentials.clientAuthorization(
                            clientConfig("integration-test-secret", "localhost", false, 8)));
            // 在同一次刷新内发送 CONNECT 和 DATA，之后不再写入，避免后续数据掩盖漏刷。
            stream.eventLoop().submit(() -> {
                stream.write(new DefaultHttp2HeadersFrame(request));
                for (int offset = 0; offset < payload.length; offset += 16 * 1024)
                    stream.write(new DefaultHttp2DataFrame(Unpooled.wrappedBuffer(payload, offset, 16 * 1024)));
                stream.flush();
            }).sync();
            assertEquals("200", status.get(5, TimeUnit.SECONDS));
            assertArrayEquals(payload, received.get(5, TimeUnit.SECONDS));
            stream.close().sync();
        } finally {
            if (connection != null) connection.close().sync();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }

    @Test
    void failedTargetDoesNotBreakSharedConnection() throws Exception {
        int unused;
        try (ServerSocket reservation = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            unused = reservation.getLocalPort();
        }
        try (Socket s = socket(client)) {
            send(s, "CONNECT 127.0.0.1:" + unused + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
        }
        assertEquals("connected", client.connectionState());
        assertEquals("", client.lastError(), "单个目标失败不应显示成全局故障");
        try (Socket s = tunnel(client, echo.port())) {
            send(s, "ok");
            assertEquals("ok", new String(s.getInputStream().readNBytes(2)));
        }
        assertEquals(1, client.connectionCount());
    }

    @Test
    void wrongPasswordCannotReachTarget() throws Exception {
        try (var bad = proxy(clientConfig("wrong", "localhost", false, 8)).start(); Socket s = socket(bad)) {
            send(s, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
            assertEquals(0, echo.accepted.get());
            assertEquals("代理账号或密码验证失败", bad.lastError());
        }
    }

    @Test
    void verifiesCertificateHostname() throws Exception {
        try (var bad = proxy(clientConfig("integration-test-secret", "wrong.invalid", false, 8)).start(); Socket s = socket(bad)) {
            send(s, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 502"));
            assertEquals(0, echo.accepted.get());
        }
    }

    @Test
    void streamsPostBodyWithoutBufferingWholeRequest() throws Exception {
        byte[] body = new byte[2 * 1024 * 1024];
        new Random(13).nextBytes(body);
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

    @Test
    void supportsChunkedPost() throws Exception {
        try (Origin http = new Origin(s -> {
            assertTrue(headers(s.getInputStream()).startsWith("POST / HTTP/1.1"));
            assertEquals("5\r\nhello\r\n0\r\n\r\n", new String(s.getInputStream().readNBytes(15), StandardCharsets.US_ASCII));
            send(s, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        }); Socket s = socket(client)) {
            send(s, "POST http://localhost:" + http.port() + "/ HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("ok", new String(s.getInputStream().readNBytes(2)));
            http.check();
        }
    }

    @Test
    void routesDirectDomainsWithoutOpeningHttp2() throws Exception {
        try (var direct = proxy(clientConfig("integration-test-secret", "localhost", true, 8)).start(); Socket s = socket(direct)) {
            send(s, "CONNECT 127.0.0.1:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            send(s, "direct");
            assertEquals("direct", new String(s.getInputStream().readNBytes(6)));
            assertEquals(0, direct.connectionCount());
        }
    }

    @Test
    void cidrBypassesProxyForLiteralAndResolvedDomainEvenWhenServerIsDown() throws Exception {
        var routedOptions = clientConfig("wrong", "localhost", false, 8);
        var routedValues = routedOptions.values();
        routedValues.setProperty("routesInline", "127.0.0.0/8\n");
        var routedConfig = new ProxyConfig(routedValues, directory);
        server.close();
        try (var direct = proxy(routedConfig).start()) {
            for (String host : List.of("127.0.0.1", "localhost")) {
                try (Socket s = socket(direct)) {
                    send(s, "CONNECT " + host + ":" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
                    assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
                    send(s, "cidr");
                    assertEquals("cidr", new String(s.getInputStream().readNBytes(4), StandardCharsets.US_ASCII));
                }
            }
            assertEquals(0, direct.connectionCount());
            assertEquals(0, server.acceptedConnections());
        }
    }

    @Test
    void nonMatchingCidrStillUsesHttp2() throws Exception {
        var routedOptions = clientConfig("integration-test-secret", "localhost", false, 8);
        var routedValues = routedOptions.values();
        routedValues.setProperty("routesInline", "10.0.0.0/8\n");
        var routedConfig = new ProxyConfig(routedValues, directory);
        try (var routed = proxy(routedConfig).start();
             Socket s = tunnel(routed, echo.port())) {
            send(s, "proxy");
            assertEquals("proxy", new String(s.getInputStream().readNBytes(5), StandardCharsets.US_ASCII));
            assertEquals(1, routed.connectionCount());
            assertEquals(1, server.acceptedConnections());
        }
    }

    @Test
    void cidrAlsoAppliesToOrdinaryHttpRequests() throws Exception {
        var routedOptions = clientConfig("wrong", "localhost", false, 8);
        var routedValues = routedOptions.values();
        routedValues.setProperty("routesInline", "127.0.0.0/8\n");
        var routedConfig = new ProxyConfig(routedValues, directory);
        try (Origin http = new Origin(s -> {
            assertTrue(headers(s.getInputStream()).startsWith("GET /cidr HTTP/1.1"));
            send(s, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        }); var direct = proxy(routedConfig).start();
             Socket s = socket(direct)) {
            send(s, "GET http://localhost:" + http.port() + "/cidr HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(s.getInputStream()).startsWith("HTTP/1.1 200"));
            assertEquals("ok", new String(s.getInputStream().readNBytes(2)));
            assertEquals(0, direct.connectionCount());
            assertEquals(0, server.acceptedConnections());
            http.check();
        }
    }

    private ProxyConfig accountClientConfig(String username, String password) throws Exception {
        var values = new Properties();
        values.setProperty("protocol", "http2");
        values.setProperty("username", username);
        values.setProperty("password", password);
        values.setProperty("port", "0");
        values.setProperty("server.host", "127.0.0.1");
        values.setProperty("server.port", Integer.toString(server.address().getPort()));
        values.setProperty("tls.ca", resource("localhost.crt"));
        values.setProperty("tls.serverName", "localhost");
        values.setProperty("connectTimeoutMillis", "3000");
        return new ProxyConfig(values, directory);
    }

    @Test
    void independentAccountsAuthenticateAndIsolateClients() throws Exception {
        client.close();
        server.close();
        Files.writeString(directory.resolve("users.properties"), "alice=alice-secret\nbob=bob-secret\n");
        var options = new Properties();
        options.setProperty("usersFile", "users.properties");
        options.setProperty("bind", "127.0.0.1");
        options.setProperty("port", "0");
        options.setProperty("tls.cert", resource("localhost.crt"));
        options.setProperty("tls.key", resource("localhost.key"));
        server = new com.blacicada.h2.Http2ProxyServer(new ProxyConfig(options, directory)).start();
        try (var alice = proxy(accountClientConfig("alice", "alice-secret")).start();
             var bob = proxy(accountClientConfig("bob", "bob-secret")).start();
             var bad = proxy(accountClientConfig("alice", "bob-secret")).start();
             Socket first = tunnel(alice, echo.port()); Socket second = tunnel(bob, echo.port());
             Socket rejected = socket(bad)) {
            send(rejected, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(rejected.getInputStream()).startsWith("HTTP/1.1 502"));
            assertEquals(2, echo.accepted.get(), "认证失败的客户端不能连接目标服务");
            send(first, "a");
            assertEquals('a', first.getInputStream().read());
            send(second, "b");
            assertEquals('b', second.getInputStream().read());
            alice.close();
            send(second, "c");
            assertEquals('c', second.getInputStream().read());
        }
    }

    @Test
    void multipleClientsHaveIndependentConnectionsAndStreamLimits() throws Exception {
        useSinglePeerStream();
        try (var second = proxy(clientConfig("integration-test-secret", "localhost", false, 1)).start();
             var third = proxy(clientConfig("integration-test-secret", "localhost", false, 1)).start();
             Socket firstTunnel = tunnel(client, echo.port());
             Socket secondTunnel = tunnel(second, echo.port());
             Socket thirdTunnel = tunnel(third, echo.port());
             var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            // 每个客户端各占一个流，验证服务端上限按 QUIC 连接分别计算。
            var sockets = List.of(firstTunnel, secondTunnel, thirdTunnel);
            var tasks = new ArrayList<Future<?>>();
            for (int i = 0; i < sockets.size(); i++) {
                Socket socket = sockets.get(i);
                String payload = "client-" + i;
                tasks.add(executor.submit(() -> {
                    for (int n = 0; n < 20; n++) {
                        send(socket, payload);
                        assertEquals(payload, new String(socket.getInputStream().readNBytes(payload.length()),
                                StandardCharsets.US_ASCII), "不同客户端的数据不能串流");
                    }
                    return null;
                }));
            }
            for (Future<?> task : tasks) task.get(10, TimeUnit.SECONDS);
            assertEquals(3, server.acceptedConnections());
            assertEquals(1, client.connectionCount());
            assertEquals(1, second.connectionCount());
            assertEquals(1, third.connectionCount());
            second.close();
            for (Socket socket : List.of(firstTunnel, thirdTunnel)) {
                send(socket, "ok");
                assertEquals("ok", new String(socket.getInputStream().readNBytes(2), StandardCharsets.US_ASCII));
            }
        }
    }

    private void useSinglePeerStream() throws Exception {
        client.close();
        server.close();
        var options = new Properties();
        options.setProperty("password", "integration-test-secret");
        options.setProperty("bind", "127.0.0.1");
        options.setProperty("port", "0");
        options.setProperty("tls.cert", resource("localhost.crt"));
        options.setProperty("tls.key", resource("localhost.key"));
        options.setProperty("maxStreams", "1");
        server = new com.blacicada.h2.Http2ProxyServer(new ProxyConfig(options, directory)).start();
        client = proxy(clientConfig("integration-test-secret", "localhost", false, 32)).start();
    }

    @Test
    void waitsForPeerStreamCreditWithoutReconnecting() throws Exception {
        useSinglePeerStream();
        try (Socket active = tunnel(client, echo.port());
             Socket waiting = socket(client);
             var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            send(waiting, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            var response = executor.submit(() -> headers(waiting.getInputStream()));
            assertThrows(TimeoutException.class, () -> response.get(200, TimeUnit.MILLISECONDS),
                    "对端额度耗尽时应等待，而不是立即返回 502");
            send(active, "x");
            assertEquals('x', active.getInputStream().read());
            active.close();
            assertTrue(response.get(5, TimeUnit.SECONDS).startsWith("HTTP/1.1 200"));
            send(waiting, "y");
            assertEquals('y', waiting.getInputStream().read());
        }
        assertEquals(1, client.connectionCount(), "额度恢复后应继续复用原连接");
    }

    @Test
    void peerCreditTimeoutPreservesActiveTunnel() throws Exception {
        useSinglePeerStream();
        try (Socket active = tunnel(client, echo.port()); Socket waiting = socket(client)) {
            send(waiting, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(waiting.getInputStream()).startsWith("HTTP/1.1 502"));
            send(active, "x");
            assertEquals('x', active.getInputStream().read());
        }
        try (Socket next = tunnel(client, echo.port())) {
            send(next, "y");
            assertEquals('y', next.getInputStream().read());
        }
        assertEquals(1, client.connectionCount(), "等待超时不得关闭共享连接或永久占用额度");
    }

    @Test
    void disconnectFailsRequestsWaitingForCredit() throws Exception {
        useSinglePeerStream();
        try (Socket active = tunnel(client, echo.port()); Socket waiting = socket(client);
             var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            send(waiting, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            var response = executor.submit(() -> headers(waiting.getInputStream()));
            assertThrows(TimeoutException.class, () -> response.get(200, TimeUnit.MILLISECONDS));
            server.disconnectClients();
            assertTrue(response.get(2, TimeUnit.SECONDS).startsWith("HTTP/1.1 502"));
            assertEquals(-1, active.getInputStream().read());
        }
        try (Socket next = tunnel(client, echo.port())) {
            send(next, "x");
            assertEquals('x', next.getInputStream().read());
        }
        assertEquals(2, client.connectionCount(), "断开后新请求应能重新建立连接");
    }

    @Test
    @Timeout(90)
    void abortedUploadsDoNotExhaustConnectionWindow() throws Exception {
        try (var upload = new Origin(socket -> {
            assertTrue(socket.getInputStream().read() >= 0);
            Thread.sleep(20);
            socket.setSoLinger(true, 0);
            // 目标在上传期间主动复位连接，服务端必须释放对应 QUIC 输入。
        })) {
            byte[] payload = new byte[1024 * 1024];
            for (int i = 0; i < 160; i++) {
                try (Socket browser = tunnel(client, upload.port())) {
                    try {
                        browser.getOutputStream().write(payload);
                        browser.getOutputStream().flush();
                        browser.getInputStream().read();
                    } catch (IOException expected) {
                        // 目标主动中断，允许浏览器端读写失败。
                    }
                }
                // 等待异步关闭传播，避免把本地并发保护误当成累计额度泄漏。
                Thread.sleep(30);
            }
            try (Socket healthy = tunnel(client, echo.port())) {
                send(healthy, "ok");
                assertEquals("ok", new String(healthy.getInputStream().readNBytes(2), StandardCharsets.US_ASCII));
            }
            assertEquals(1, client.connectionCount(), "目标取消上传后仍应复用同一条连接");
        }
    }

    @Test
    @Timeout(90)
    void abortedDownloadsDoNotExhaustConnectionWindow() throws Exception {
        try (var download = new Origin(socket -> {
            byte[] chunk = new byte[64 * 1024];
            try {
                for (int i = 0; i < 512; i++) socket.getOutputStream().write(chunk);
            } catch (IOException expected) {
                // 浏览器故意中断下载，允许目标写入失败。
            }
        })) {
            for (int i = 0; i < 160; i++) {
                try (Socket browser = tunnel(client, download.port())) {
                    assertEquals(0, browser.getInputStream().read());
                    // 留出少量时间制造积压，然后用 RST 模拟浏览器取消下载。
                    Thread.sleep(20);
                    browser.setSoLinger(true, 0);
                }
            }
            try (Socket healthy = tunnel(client, echo.port())) {
                send(healthy, "ok");
                assertEquals("ok", new String(healthy.getInputStream().readNBytes(2), StandardCharsets.US_ASCII));
            }
            assertEquals(1, client.connectionCount(), "取消下载后仍应复用同一条连接");
        }
    }

    @Test
    void closedTunnelsReplenishStreamCredit() throws Exception {
        // 请求总数超过服务端默认额度，且每次只保留少量活跃流。
        for (int i = 0; i < 600; i++) {
            try (Socket current = tunnel(client, echo.port())) {
                send(current, "x");
                assertEquals('x', current.getInputStream().read());
            }
        }
        assertEquals(1, client.connectionCount(), "连续请求应复用同一条 QUIC 连接");
    }

    @Test
    void goAwayPreservesExistingTunnelAndNewRequestUsesNewConnection() throws Exception {
        try (Socket old = tunnel(client, echo.port())) {
            server.drainConnections();
            // 先让已有隧道往返一次，保证 GOAWAY 已被读取。
            send(old, "a");
            assertEquals('a', old.getInputStream().read());
            try (Socket next = tunnel(client, echo.port())) {
                send(next, "b");
                assertEquals('b', next.getInputStream().read());
                send(old, "c");
                assertEquals('c', old.getInputStream().read());
            }
        }
        assertEquals(2, client.connectionCount());
    }

    @Test
    void reconnectsAfterConnectionLoss() throws Exception {
        try (Socket first = tunnel(client, echo.port())) {
            send(first, "a");
            assertEquals('a', first.getInputStream().read());
            server.disconnectClients();
            assertEquals(-1, first.getInputStream().read());
        }
        try (Socket second = tunnel(client, echo.port())) {
            send(second, "b");
            assertEquals('b', second.getInputStream().read());
        }
        assertEquals(2, client.connectionCount());
    }

    @Test
    void streamLimitDoesNotCloseExistingTunnels() throws Exception {
        try (var limited = proxy(clientConfig("integration-test-secret", "localhost", false, 1)).start();
             Socket active = tunnel(limited, echo.port()); Socket extra = socket(limited)) {
            send(extra, "CONNECT localhost:" + echo.port() + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            assertTrue(headers(extra.getInputStream()).startsWith("HTTP/1.1 502"));
            send(active, "alive");
            assertEquals("alive", new String(active.getInputStream().readNBytes(5)));
            assertEquals("connected", limited.connectionState());
            assertEquals("", limited.lastError(), "并发额度耗尽不代表服务端连接断开");
        }
    }

    @FunctionalInterface
    interface SocketAction {
        void run(Socket socket) throws Exception;
    }

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
                        Socket socket = listener.accept();
                        accepted.incrementAndGet();
                        sockets.add(socket);
                        socket.setSoTimeout(15000);
                        tasks.add(executor.submit(() -> {
                            try (socket) {
                                action.run(socket);
                            } finally {
                                sockets.remove(socket);
                            }
                            return null;
                        }));
                    } catch (IOException e) {
                        if (!listener.isClosed()) throw new UncheckedIOException(e);
                    }
                }
            });
        }

        int port() {
            return listener.getLocalPort();
        }

        void check() throws Exception {
            for (var task : tasks) task.get(15, TimeUnit.SECONDS);
        }

        @Override
        public void close() throws Exception {
            listener.close();
            for (Socket socket : sockets) socket.close();
            executor.shutdownNow();
            executor.awaitTermination(5, TimeUnit.SECONDS);
        }
    }
}
