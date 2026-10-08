package com.blacicada.proxy;

import com.blacicada.common.*;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.*;
import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class Http2TimeoutDiagnosticsTest {
    private Path resource(String name) throws Exception { return Path.of(getClass().getResource("/tls/" + name).toURI()); }
    @Test void noPeerCreditReportsQueueWithoutCreatingStream() throws Exception { verify(0); }
    @Test void unansweredConnectReportsStreamAndResponsePhase() throws Exception { verify(1); }
    private void verify(int maximum) throws Exception {
        var group = new NioEventLoopGroup(1);
        var peers = new DefaultChannelGroup(group.next());
        var resolver = Transport.resolver();
        Channel listener = null;
        AtomicInteger received = new AtomicInteger();
        var ssl = SslContextBuilder.forServer(resource("localhost.crt").toFile(), resource("localhost.key").toFile())
                .sslProvider(SslProvider.JDK).applicationProtocolConfig(new ApplicationProtocolConfig(
                        ApplicationProtocolConfig.Protocol.ALPN, ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                        ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2")).build();
        try {
            listener = new ServerBootstrap().group(group).channel(NioServerSocketChannel.class)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override protected void initChannel(SocketChannel channel) {
                            peers.add(channel); channel.pipeline().addLast(ssl.newHandler(channel.alloc()));
                            channel.pipeline().addLast(new ApplicationProtocolNegotiationHandler("") {
                                @Override protected void configurePipeline(ChannelHandlerContext ctx, String protocol) {
                                    ctx.pipeline().addLast(Http2FrameCodecBuilder.forServer().initialSettings(
                                            new Http2Settings().maxConcurrentStreams(maximum)).build());
                                    ctx.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Http2StreamChannel>() {
                                        @Override protected void initChannel(Http2StreamChannel stream) {
                                            stream.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                                @Override public void channelRead(ChannelHandlerContext c, Object message) {
                                                    // 故意只接收 CONNECT，不返回响应，用来隔离传输正常但业务响应缺失的场景。
                                                    if (message instanceof Http2HeadersFrame) received.incrementAndGet();
                                                    ReferenceCountUtil.release(message);
                                                }
                                            });
                                        }
                                    }));
                                }
                            });
                        }
                    }).bind("127.0.0.1", 0).sync().channel();
            Properties properties = new Properties();
            properties.setProperty("server.host", "127.0.0.1");
            properties.setProperty("server.port", "" + ((InetSocketAddress) listener.localAddress()).getPort());
            properties.setProperty("password", "diagnostic-test-secret");
            properties.setProperty("tls.ca", resource("localhost.crt").toString());
            properties.setProperty("tls.serverName", "localhost");
            properties.setProperty("connectTimeoutMillis", "1000");
            try (var session = new Http2Session(group.next(), new ProxyConfig(properties, Path.of(".")), resolver)) {
                var request = session.open(new Authority("example.test", 443));
                assertTrue(request.await(6000)); assertFalse(request.isSuccess());
                String message = request.cause().getMessage();
                assertTrue(message.startsWith(maximum == 0 ? "等待 HTTP/2 流额度超时" : "等待 HTTP/2 CONNECT 响应超时"), message);
                assertTrue(message.contains("目标=example.test:443"));
                assertTrue(message.contains("连接 ID=")); assertTrue(message.contains("对端并发上限=" + maximum));
                assertTrue(message.contains("本连接占用=" + maximum));
                assertTrue(message.contains("排队=" + (maximum == 0 ? 1 : 0)));
                assertTrue(message.contains("总等待=")); assertTrue(message.contains("当前阶段耗时="));
                assertEquals(maximum, received.get());
                if (maximum == 0) assertTrue(message.contains("流 ID=未分配"));
                else assertTrue(message.matches(".*流 ID=[0-9]+，.*"), message);
                assertFalse(message.contains("diagnostic-test-secret"));
                assertEquals("connected", session.connectionState(), "诊断增强不应改变共享连接存活策略");
            }
        } finally {
            if (listener != null) listener.close().syncUninterruptibly();
            peers.close().awaitUninterruptibly(); resolver.close();
            group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
