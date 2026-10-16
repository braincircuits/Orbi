package com.blacicada.proxy;

import com.blacicada.common.DnsTunnel;
import com.blacicada.common.ProxyConfig;
import com.blacicada.common.Transport;
import com.blacicada.common.UdpTunnel;
import com.blacicada.common.h3.H3DataCodec;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.http3.*;
import io.netty.handler.codec.quic.*;
import io.netty.util.concurrent.GlobalEventExecutor;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.Properties;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static com.blacicada.proxy.KernelDnsTest.*;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class Http3DnsReadIntegrationTest {
    private String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void unknownFramesAndFragmentedResponsesDoNotStallProxyDns(boolean udp) throws Exception {
        var group = new NioEventLoopGroup(1);
        var connections = new DefaultChannelGroup(GlobalEventExecutor.INSTANCE);
        Channel listener = null;
        var responseSent = new CompletableFuture<Void>();
        var requests = new AtomicInteger();
        try {
            var ssl = QuicSslContextBuilder.forServer(Path.of(resource("localhost.key")).toFile(), null,
                            Path.of(resource("localhost.crt")).toFile())
                    .applicationProtocols(Http3.supportedApplicationProtocols()).build();
            var codec = Transport.limits(Http3.newQuicServerCodecBuilder(), new ProxyConfig(new Properties(), Path.of(".")))
                    .sslContext(ssl).tokenHandler(InsecureQuicTokenHandler.INSTANCE)
                    .handler(new ChannelInitializer<QuicChannel>() {
                        @Override
                        protected void initChannel(QuicChannel channel) {
                            connections.add(channel);
                            channel.pipeline().addLast(new Http3ServerConnectionHandler(new ChannelInitializer<QuicStreamChannel>() {
                                @Override
                                protected void initChannel(QuicStreamChannel stream) {
                                    stream.pipeline().addLast(new SimpleChannelInboundHandler<Http3HeadersFrame>() {
                                        @Override
                                        protected void channelRead0(ChannelHandlerContext ctx, Http3HeadersFrame headers) {
                                            var reply = new DefaultHttp3HeadersFrame();
                                            reply.headers().status("200").set(DnsTunnel.HEADER, headers.headers().get(DnsTunnel.HEADER));
                                            if (udp) reply.headers().set(UdpTunnel.HEADER, UdpTunnel.VALUE);
                                            ctx.writeAndFlush(reply);
                                            ctx.pipeline().replace(this, "data", new H3DataCodec());
                                            KernelDns.framing(ctx.pipeline());
                                            ctx.pipeline().addLast(new SimpleChannelInboundHandler<ByteBuf>() {
                                                @Override
                                                protected void channelRead0(ChannelHandlerContext ctx, ByteBuf data) throws Exception {
                                                    requests.incrementAndGet();
                                                    byte[] query = new byte[data.readableBytes()];
                                                    data.readBytes(query);
                                                    byte[] framed = frame(answer(query, "192.0.2.42", 60));
                                                    // 从长度解码器之前写入已组好的 DNS 帧，避免再次添加长度前缀。
                                                    var output = ctx.pipeline().context(LengthFieldBasedFrameDecoder.class);
                                                    output.writeAndFlush(new DefaultHttp3UnknownFrame(0x40, Unpooled.EMPTY_BUFFER));
                                                    // 将未知帧、半个长度前缀和完整回答分开交付，覆盖连续多个读取轮次。
                                                    ctx.executor().schedule(() -> output.writeAndFlush(Unpooled.wrappedBuffer(Arrays.copyOf(framed, 1))),
                                                            100, TimeUnit.MILLISECONDS);
                                                    ctx.executor().schedule(() -> output.writeAndFlush(new DefaultHttp3UnknownFrame(0x40, Unpooled.EMPTY_BUFFER)),
                                                            200, TimeUnit.MILLISECONDS);
                                                    ctx.executor().schedule(() -> output.writeAndFlush(Unpooled.wrappedBuffer(Arrays.copyOfRange(framed, 1, framed.length)))
                                                            .addListener(sent -> {
                                                                if (sent.isSuccess()) responseSent.complete(null);
                                                                else responseSent.completeExceptionally(sent.cause());
                                                            }), 300, TimeUnit.MILLISECONDS);
                                                }
                                            });
                                        }
                                    });
                                }
                            }));
                        }
                    }).build();
            listener = new Bootstrap().group(group).channel(NioDatagramChannel.class).handler(codec)
                    .bind(new java.net.InetSocketAddress("127.0.0.1", 0)).sync().channel();
            var values = new Properties();
            values.setProperty("protocol", "http3");
            values.setProperty("port", "0");
            values.setProperty("password", "dns-read-test");
            values.setProperty("server.host", "127.0.0.1");
            values.setProperty("server.port", Integer.toString(((java.net.InetSocketAddress) listener.localAddress()).getPort()));
            values.setProperty("tls.ca", resource("localhost.crt"));
            values.setProperty("tls.serverName", "localhost");
            values.setProperty("connectTimeoutMillis", "3000");
            try (var client = new LocalProxyServer(TestKernelConfig.from(new ProxyConfig(values, Path.of(".")))).start();
                 var browser = connect(client, "203.0.113.53:53", udp, frame(query("read.example", 1, 42)))) {
                responseSent.get(4, TimeUnit.SECONDS);
                browser.setSoTimeout(1000);
                var response = new DnsMessage(receive(browser), true);
                assertEquals(42, response.id);
                assertTrue(response.addresses().containsKey("192.0.2.42"));
                assertEquals(1, requests.get(), "忽略未知帧后应继续读取当前回答，不能依赖超时换上游");
                assertEquals(1, client.connectionCount());
            }
        } finally {
            connections.close().awaitUninterruptibly();
            if (listener != null) listener.close().awaitUninterruptibly();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
