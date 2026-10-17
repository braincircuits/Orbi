package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.ProxyConfig;
import com.blacicada.common.Transport;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(20)
class Http2SessionLifecycleTest {
    private Path resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI());
    }

    @ParameterizedTest
    @ValueSource(ints = {0, 1})
    void unansweredConnectionIsRetiredAndNextRequestReconnects(int initialMaximum) throws Exception {
        verifyTimeout(initialMaximum, false);
    }

    @ParameterizedTest
    @ValueSource(ints = {0, 1})
    void responsiveConnectionSurvivesSlowConnectOrMissingStreamCredit(int initialMaximum) throws Exception {
        verifyTimeout(initialMaximum, true);
    }

    private void verifyTimeout(int initialMaximum, boolean responsive) throws Exception {
        var group = new NioEventLoopGroup(1);
        var peers = new DefaultChannelGroup(group.next());
        var resolver = Transport.resolver();
        var dropping = new AtomicBoolean();
        var maximum = new AtomicInteger(initialMaximum);
        var answerConnect = new AtomicBoolean();
        var tls = SslContextBuilder.forServer(resource("localhost.crt").toFile(), resource("localhost.key").toFile())
                .sslProvider(SslProvider.JDK).applicationProtocolConfig(new ApplicationProtocolConfig(
                        ApplicationProtocolConfig.Protocol.ALPN, ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                        ApplicationProtocolConfig.SelectedListenerFailureBehavior.FATAL_ALERT, "h2")).build();
        Channel listener = null;
        try {
            listener = new ServerBootstrap().group(group).channel(NioServerSocketChannel.class)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override
                        protected void initChannel(SocketChannel channel) {
                            peers.add(channel);
                            channel.pipeline().addLast(tls.newHandler(channel.alloc()));
                            channel.pipeline().addLast(new ApplicationProtocolNegotiationHandler("") {
                                @Override
                                protected void configurePipeline(ChannelHandlerContext ctx, String protocol) {
                                    ctx.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                        @Override
                                        public void channelRead(ChannelHandlerContext context, Object message) {
                                            // 保持 TCP 活跃，但让 HTTP/2 不再收到任何请求或 PING。
                                            if (dropping.get()) ReferenceCountUtil.release(message);
                                            else context.fireChannelRead(message);
                                        }
                                    });
                                    ctx.pipeline().addLast(Http2FrameCodecBuilder.forServer().initialSettings(
                                            new Http2Settings().maxConcurrentStreams(maximum.get())).build());
                                    ctx.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Http2StreamChannel>() {
                                        @Override
                                        protected void initChannel(Http2StreamChannel stream) {
                                            stream.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                                @Override
                                                public void channelRead(ChannelHandlerContext context, Object message) {
                                                    if (message instanceof Http2HeadersFrame && answerConnect.get())
                                                        context.writeAndFlush(new DefaultHttp2HeadersFrame(new DefaultHttp2Headers().status("200")));
                                                    ReferenceCountUtil.release(message);
                                                }
                                            });
                                        }
                                    }));
                                }
                            });
                        }
                    }).bind("127.0.0.1", 0).sync().channel();
            var options = new Properties();
            options.setProperty("server.host", "127.0.0.1");
            options.setProperty("server.port", Integer.toString(((InetSocketAddress) listener.localAddress()).getPort()));
            options.setProperty("password", "lifecycle-test");
            options.setProperty("tls.ca", resource("localhost.crt").toString());
            options.setProperty("tls.serverName", "localhost");
            options.setProperty("connectTimeoutMillis", "1000");
            try (var session = new Http2Session(group.next(), new ProxyConfig(options, Path.of(".")), resolver)) {
                var initialPing = session.latency();
                assertTrue(initialPing.await(3000));
                assertTrue(initialPing.isSuccess(), () -> String.valueOf(initialPing.cause()));
                assertEquals(1, session.connectionCount());
                dropping.set(!responsive);
                var stalled = session.open(new Authority("example.test", 443));
                assertTrue(stalled.await(3000));
                assertFalse(stalled.isSuccess());
                if (responsive) {
                    var ping = session.latency();
                    assertTrue(ping.await(3000));
                    assertTrue(ping.isSuccess(), () -> String.valueOf(ping.cause()));
                    assertEquals("connected", session.connectionState());
                    for (Channel peer : peers)
                        peer.writeAndFlush(new DefaultHttp2SettingsFrame(new Http2Settings().maxConcurrentStreams(1))).sync();
                } else {
                    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(7);
                    while (session.connectionState().equals("connected") && System.nanoTime() < deadline) Thread.sleep(10);
                    assertNotEquals("connected", session.connectionState(), "请求超时且 PING 无响应时不能永久复用失效连接");
                }
                maximum.set(1);
                answerConnect.set(true);
                dropping.set(false);
                var recovered = session.open(new Authority("example.test", 443));
                assertTrue(recovered.await(3000));
                assertTrue(recovered.isSuccess(), () -> String.valueOf(recovered.cause()));
                recovered.getNow().close().sync();
                assertEquals(responsive ? 1 : 2, session.connectionCount(), "只重连已确认无响应的主连接");
            }
        } finally {
            if (listener != null) listener.close().syncUninterruptibly();
            peers.close().awaitUninterruptibly();
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
