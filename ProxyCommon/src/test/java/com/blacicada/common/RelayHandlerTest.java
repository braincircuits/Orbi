package com.blacicada.common;

import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Random;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class RelayHandlerTest {
    @Test
    void productionTcpAllocatorsAllowMultipleMessagesPerRead() throws Exception {
        var networks = new ArrayList<OutboundNetwork>();
        networks.add(OutboundNetwork.DEFAULT);
        if (System.getProperty("os.name").startsWith("Mac"))
            networks.add(new OutboundNetwork(java.net.NetworkInterface.getByName("lo0").getIndex()));
        for (var network : networks) {
            var socket = network.tcp();
            try {
                MaxMessagesRecvByteBufAllocator allocator = socket.config().getRecvByteBufAllocator();
                assertTrue(allocator.maxMessagesPerRead() > 1, "生产 TCP 接收分配器必须允许同轮批读");
            } finally {
                socket.unsafe().closeForcibly();
            }
        }
    }

    private static final class Operations extends ChannelOutboundHandlerAdapter {
        int flushes, reads;

        @Override
        public void flush(ChannelHandlerContext ctx) {
            flushes++;
            ctx.flush();
        }

        @Override
        public void read(ChannelHandlerContext ctx) {
            reads++;
            ctx.read();
        }
    }

    @Test
    void batchesReadyBuffersAndFlushesSmallRequestsWithoutWaiting() {
        var operations = new Operations();
        var peer = new EmbeddedChannel(operations);
        var reads = new Operations();
        var source = new EmbeddedChannel(reads, new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{1, 2}));
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{3}));
            assertFalse(source.config().isAutoRead(), "非套接字通道保持手动读取，避免启读同步重入");
            assertEquals(0, operations.flushes);
            assertNull(peer.readOutbound());
            int readsBeforeFlush = reads.reads;
            source.pipeline().fireChannelReadComplete();
            assertFalse(source.config().isAutoRead());
            assertEquals(1, operations.flushes);
            assertEquals(readsBeforeFlush + 1, reads.reads);
            ByteBuf first = peer.readOutbound(), second = peer.readOutbound();
            assertEquals(2, first.readableBytes());
            assertEquals(3, second.readByte());
            first.release();
            second.release();

            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{4}));
            source.pipeline().fireChannelReadComplete();
            assertEquals(2, operations.flushes);
            ByteBuf small = peer.readOutbound();
            assertEquals(4, small.readByte());
            small.release();
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void highWatermarkStopsTheBatchAndCompletionResumesManualReading() {
        var peer = new EmbeddedChannel();
        peer.config().setWriteBufferWaterMark(Transport.WATERMARK);
        var reads = new Operations();
        var source = new EmbeddedChannel(reads, new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            int messages = 0;
            do {
                source.pipeline().fireChannelRead(Unpooled.buffer(8192).writeZero(8192));
                messages++;
            } while (peer.isWritable() && messages < 16);
            assertTrue(messages <= 8, "写入高水位应在当前读取轮次内停止预取");
            assertFalse(peer.isWritable());
            assertFalse(source.config().isAutoRead());
            int before = reads.reads;
            source.pipeline().fireChannelReadComplete();
            assertTrue(peer.isWritable());
            assertEquals(before + 1, reads.reads);
            assertFalse(source.config().isAutoRead());
            for (int i = 0; i < messages; i++) ((ByteBuf) peer.readOutbound()).release();
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void completedRequestBodyDoesNotRestartReading() {
        var peer = new EmbeddedChannel();
        var reads = new Operations();
        var source = new EmbeddedChannel(reads, new RelayHandler(peer) {
            @Override
            protected boolean canRead() {
                return false;
            }
        });
        source.config().setAutoRead(false);
        try {
            int before = reads.reads;
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{1}));
            source.pipeline().fireChannelReadComplete();
            assertFalse(source.config().isAutoRead());
            assertEquals(before, reads.reads);
            ((ByteBuf) peer.readOutbound()).release();
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void halfCloseWaitsForEveryBufferedWrite() {
        var messages = new ArrayList<Object>();
        var promises = new ArrayList<ChannelPromise>();
        var peer = new EmbeddedChannel(new ChannelOutboundHandlerAdapter() {
            @Override
            public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) {
                messages.add(message);
                promises.add(promise);
            }
        });
        var source = new EmbeddedChannel(new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{1}));
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{2}));
            source.pipeline().fireChannelReadComplete();
            source.pipeline().fireUserEventTriggered(ChannelInputShutdownEvent.INSTANCE);
            assertTrue(peer.isActive());
            promises.get(0).setSuccess();
            assertTrue(peer.isActive());
            promises.get(1).setSuccess();
            assertFalse(peer.isActive());
            assertFalse(source.config().isAutoRead());
        } finally {
            messages.forEach(ReferenceCountUtil::release);
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void synchronousWriteFailureCannotReenableReading() {
        var peer = new EmbeddedChannel(new ChannelOutboundHandlerAdapter() {
            @Override
            public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) {
                ReferenceCountUtil.release(message);
                promise.setFailure(new java.io.IOException("模拟写入失败"));
            }
        });
        var source = new EmbeddedChannel(new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            source.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{1}));
            assertFalse(source.isActive());
            assertFalse(peer.isActive());
            assertFalse(source.config().isAutoRead());
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void sameEventLoopBatchesSocketReadsAndPreservesHalfClose() throws Exception {
        transferAcrossLoops(false);
    }

    @Test
    void differentEventLoopsPreservePayloadAndHalfClose() throws Exception {
        transferAcrossLoops(true);
    }

    private void transferAcrossLoops(boolean separateLoops) throws Exception {
        var sourceGroup = new NioEventLoopGroup(1);
        var peerGroup = separateLoops ? new NioEventLoopGroup(1) : sourceGroup;
        var largestBatch = new java.util.concurrent.atomic.AtomicInteger();
        Channel listener = null;
        byte[] payload = new byte[256 * 1024];
        new Random(23).nextBytes(payload);
        try (var origin = new ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress());
             var executor = Executors.newSingleThreadExecutor()) {
            var echoed = executor.submit(() -> {
                try (var socket = origin.accept()) {
                    socket.setSoTimeout(5000);
                    byte[] received = socket.getInputStream().readAllBytes();
                    socket.getOutputStream().write(received);
                    return received;
                }
            });
            listener = new ServerBootstrap().group(sourceGroup).channel(NioServerSocketChannel.class)
                    .childOption(ChannelOption.AUTO_READ, false).childOption(ChannelOption.ALLOW_HALF_CLOSURE, true)
                    // 替换分配器不会继承 SocketChannel 的默认每轮条数，需显式保留批读额度。
                    .childOption(ChannelOption.RCVBUF_ALLOCATOR, new FixedRecvByteBufAllocator(1024).maxMessagesPerRead(16))
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override
                        protected void initChannel(SocketChannel source) {
                            source.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                private int messages;

                                @Override
                                public void channelRead(ChannelHandlerContext ctx, Object message) {
                                    messages++;
                                    ctx.fireChannelRead(message);
                                }

                                @Override
                                public void channelReadComplete(ChannelHandlerContext ctx) {
                                    largestBatch.accumulateAndGet(messages, Math::max);
                                    messages = 0;
                                    ctx.fireChannelReadComplete();
                                }
                            });
                            new Bootstrap().group(peerGroup).channel(NioSocketChannel.class)
                                    .option(ChannelOption.AUTO_READ, false).option(ChannelOption.ALLOW_HALF_CLOSURE, true)
                                    .handler(new ChannelInitializer<SocketChannel>() {
                                        @Override
                                        protected void initChannel(SocketChannel peer) {
                                            peer.pipeline().addLast(new RelayHandler(source));
                                        }
                                    }).connect(origin.getLocalSocketAddress()).addListener((ChannelFutureListener) connected -> {
                                        if (!connected.isSuccess()) {
                                            source.close();
                                            return;
                                        }
                                        source.eventLoop().execute(() -> {
                                            source.pipeline().addLast(new RelayHandler(connected.channel()));
                                            source.read();
                                            connected.channel().read();
                                        });
                                    });
                        }
                    }).bind(new InetSocketAddress("127.0.0.1", 0)).sync().channel();
            try (var browser = new Socket()) {
                browser.connect(listener.localAddress());
                browser.setSoTimeout(5000);
                browser.getOutputStream().write(payload);
                browser.shutdownOutput();
                assertArrayEquals(payload, browser.getInputStream().readAllBytes());
                assertArrayEquals(payload, echoed.get(5, TimeUnit.SECONDS));
                if (!separateLoops) assertTrue(largestBatch.get() > 1, "真实 TCP 同一读取轮次应合并多个缓冲区");
            }
        } finally {
            if (listener != null) listener.close().sync();
            sourceGroup.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
            if (separateLoops) peerGroup.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }
}
