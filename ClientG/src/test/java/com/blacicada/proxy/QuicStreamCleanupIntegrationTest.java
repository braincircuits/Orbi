package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.common.Transport;
import com.blacicada.common.h3.QuicStreamCleanupHandler;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.group.DefaultChannelGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.handler.codec.quic.*;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class QuicStreamCleanupIntegrationTest {
    private Path resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI());
    }

    @Test
    void closingInputAfterAcknowledgedFinReplenishesPeerCredit() throws Exception {
        verifyClose(true);
    }

    @Test
    void closingOpenOutputPreservesBufferedResponse() throws Exception {
        verifyClose(false);
    }

    private void verifyClose(boolean outputAlreadyShutdown) throws Exception {
        var group = new NioEventLoopGroup(1);
        var channels = new DefaultChannelGroup(group.next());
        var serverClosed = new CompletableFuture<Void>();
        var received = new AtomicInteger();
        int responseBytes = outputAlreadyShutdown ? 0 : 64 * 1024;
        try {
            var values = new Properties();
            values.setProperty("maxStreams", "1");
            var config = new ProxyConfig(values, Path.of("."));
            var serverSsl = QuicSslContextBuilder.forServer(resource("localhost.key").toFile(), null,
                    resource("localhost.crt").toFile()).applicationProtocols("stream-cleanup-test").build();
            var serverCodec = Transport.limits(new QuicServerCodecBuilder(), config).sslContext(serverSsl)
                    .tokenHandler(InsecureQuicTokenHandler.INSTANCE)
                    .handler(new ChannelInitializer<QuicChannel>() {
                        @Override
                        protected void initChannel(QuicChannel channel) {
                            channels.add(channel);
                        }
                    })
                    .streamOption(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .streamHandler(new ChannelInitializer<QuicStreamChannel>() {
                        @Override
                        protected void initChannel(QuicStreamChannel stream) {
                            stream.pipeline().addLast(new QuicStreamCleanupHandler(), new ChannelInboundHandlerAdapter() {
                                @Override
                                public void channelRead(ChannelHandlerContext ctx, Object msg) {
                                    ReferenceCountUtil.release(msg);
                                    if (outputAlreadyShutdown) {
                                        stream.shutdownOutput().addListener(sent -> {
                                            // 先让 FIN 被确认，再关闭仍未结束的接收方向。
                                            ctx.executor().schedule(() -> stream.close().addListener(closed ->
                                                    serverClosed.complete(null)), 500, TimeUnit.MILLISECONDS);
                                        });
                                    } else {
                                        // 应用写入完成不等于对端已收到；完整关闭不能重置仍有响应的输出方向。
                                        stream.writeAndFlush(Unpooled.wrappedBuffer(new byte[responseBytes]))
                                                .addListener(sent -> stream.close().addListener(closed ->
                                                        serverClosed.complete(null)));
                                    }
                                }
                            });
                        }
                    }).build();
            Channel server = new Bootstrap().group(group).channel(NioDatagramChannel.class).handler(serverCodec)
                    .bind("127.0.0.1", 0).sync().channel();
            channels.add(server);
            var clientSsl = QuicSslContextBuilder.forClient().trustManager(resource("localhost.crt").toFile())
                    .applicationProtocols("stream-cleanup-test").build();
            Channel udp = new Bootstrap().group(group).channel(NioDatagramChannel.class)
                    .handler(Transport.limits(new QuicClientCodecBuilder(), config).sslEngineProvider(channel ->
                            clientSsl.newEngine(channel.alloc(), "localhost", 443)).build())
                    .bind("127.0.0.1", 0).sync().channel();
            channels.add(udp);
            QuicChannel connection = QuicChannel.newBootstrap(udp).handler(new ChannelInboundHandlerAdapter())
                    .remoteAddress((InetSocketAddress) server.localAddress()).connect().sync().getNow();
            channels.add(connection);
            QuicStreamChannel stream = connection.newStreamBootstrap().type(QuicStreamType.BIDIRECTIONAL)
                    .option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    .option(ChannelOption.AUTO_READ, outputAlreadyShutdown).handler(new ChannelInboundHandlerAdapter() {
                        @Override
                        public void channelRead(ChannelHandlerContext ctx, Object msg) {
                            received.addAndGet(((io.netty.buffer.ByteBuf) msg).readableBytes());
                            ReferenceCountUtil.release(msg);
                        }
                    }).create().sync().getNow();
            stream.writeAndFlush(Unpooled.wrappedBuffer(new byte[]{1})).sync();
            serverClosed.get(3, TimeUnit.SECONDS);
            stream.config().setAutoRead(true);
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while ((connection.peerAllowedStreams(QuicStreamType.BIDIRECTIONAL) == 0 || received.get() < responseBytes)
                    && System.nanoTime() < deadline) Thread.sleep(10);
            assertEquals(responseBytes, received.get(), "普通关闭必须完整交付已经写入的响应");
            assertEquals(1, connection.peerAllowedStreams(QuicStreamType.BIDIRECTIONAL),
                    "服务端完整关闭已确认 FIN 的流后，必须归还额度");
        } finally {
            channels.close().awaitUninterruptibly();
            group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
