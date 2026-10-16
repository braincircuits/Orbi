package com.blacicada.common;

import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFuture;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.WriteBufferWaterMark;
import io.netty.channel.embedded.EmbeddedChannel;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class UdpTunnelTest {
    private static final class BlockedFlush extends ChannelOutboundHandlerAdapter {
        boolean blocked = true;

        @Override
        public void flush(ChannelHandlerContext ctx) {
            if (!blocked) ctx.flush();
        }
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void emptyPacketWaitsForEarlierWritesUnderBackpressure(boolean protectedEgress) throws Exception {
        if (protectedEgress) Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        var network = new OutboundNetwork(protectedEgress ? NetworkInterface.getByName("lo0").getIndex() : 0);
        var group = network.newGroup();
        var loop = group.next();
        var resolver = network.resolver();
        Channel peer = null;
        try (var origin = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            origin.setSoTimeout(150);
            peer = UdpTunnel.connect(loop, resolver,
                    new InetSocketAddress("127.0.0.1", origin.getLocalPort()), network).sync().getNow();
            Channel destination = peer;
            var gate = new BlockedFlush();
            List<ChannelFuture> writes = loop.submit(() -> {
                // 前序数据已进入真实发送队列，但刷新暂不推进，模拟套接字发送积压。
                destination.pipeline().addFirst("blockedFlush", gate);
                destination.config().setWriteBufferWaterMark(new WriteBufferWaterMark(64, 128));
                return List.of(destination.writeAndFlush(Unpooled.wrappedBuffer(new byte[]{1, 2, 3})),
                        destination.writeAndFlush(Unpooled.EMPTY_BUFFER),
                        destination.writeAndFlush(Unpooled.wrappedBuffer(new byte[]{4, 5})),
                        destination.write(Unpooled.EMPTY_BUFFER));
            }).sync().getNow();
            assertTrue(writes.stream().noneMatch(ChannelFuture::isDone), "空报文必须等待前序报文实际发送");
            assertFalse(peer.isWritable(), "排队中的报文必须计入通道写水位");
            assertThrows(SocketTimeoutException.class, () -> origin.receive(new DatagramPacket(new byte[16], 16)));
            loop.submit(() -> {
                gate.blocked = false;
                // 只恢复下游刷新，不能把最后一个尚未刷新的空报文一并放行。
                destination.pipeline().context(gate).flush();
            }).sync();
            origin.setSoTimeout(3000);
            for (byte[] expected : List.of(new byte[]{1, 2, 3}, new byte[0], new byte[]{4, 5})) {
                var packet = new DatagramPacket(new byte[16], 16);
                origin.receive(packet);
                assertArrayEquals(expected, Arrays.copyOf(packet.getData(), packet.getLength()));
            }
            for (var write : writes.subList(0, 3)) assertTrue(write.await(3, TimeUnit.SECONDS) && write.isSuccess());
            assertFalse(writes.getLast().isDone(), "前序写入完成不能越过后续报文的刷新边界");
            origin.setSoTimeout(150);
            assertThrows(SocketTimeoutException.class, () -> origin.receive(new DatagramPacket(new byte[16], 16)));
            peer.flush();
            origin.setSoTimeout(3000);
            var last = new DatagramPacket(new byte[16], 16);
            origin.receive(last);
            assertEquals(0, last.getLength());
            assertTrue(writes.getLast().await(3, TimeUnit.SECONDS) && writes.getLast().isSuccess());
            loop.submit(() -> {}).sync();
            assertTrue(peer.isWritable(), "发送完成后必须归还写水位计费");
        } finally {
            if (peer != null) peer.close().sync();
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void closingUnflushedEmptyPacketFailsItsWriteWithoutSending(boolean protectedEgress) throws Exception {
        if (protectedEgress) Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        var network = new OutboundNetwork(protectedEgress ? NetworkInterface.getByName("lo0").getIndex() : 0);
        var group = network.newGroup();
        var loop = group.next();
        var resolver = network.resolver();
        Channel peer = null;
        try (var origin = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            origin.setSoTimeout(150);
            peer = UdpTunnel.connect(loop, resolver,
                    new InetSocketAddress("127.0.0.1", origin.getLocalPort()), network).sync().getNow();
            Channel destination = peer;
            var payload = Unpooled.buffer(1);
            var write = loop.submit(() -> destination.write(payload)).sync().getNow();
            assertFalse(write.isDone(), "未刷新时不能提前发送空报文");
            peer.close().sync();
            assertTrue(write.await(3, TimeUnit.SECONDS));
            assertFalse(write.isSuccess(), "关闭时必须使未发送报文的写入失败");
            assertEquals(0, payload.refCnt(), "关闭时必须释放排队报文的引用");
            assertThrows(SocketTimeoutException.class, () -> origin.receive(new DatagramPacket(new byte[16], 16)));
        } finally {
            if (peer != null) peer.close().sync();
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void coalescedNonemptyEmptyNonemptyPacketsKeepOrderBeforeReadComplete(boolean protectedEgress) throws Exception {
        if (protectedEgress) Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        var network = new OutboundNetwork(protectedEgress ? NetworkInterface.getByName("lo0").getIndex() : 0);
        var group = network.newGroup();
        var resolver = network.resolver();
        Channel peer = null;
        EmbeddedChannel source = null;
        try (var origin = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            origin.setSoTimeout(3000);
            peer = UdpTunnel.connect(group.next(), resolver,
                    new InetSocketAddress("127.0.0.1", origin.getLocalPort()), network).sync().getNow();
            Channel destination = peer;
            source = group.next().submit(() -> {
                var stream = new EmbeddedChannel(new UdpFrameCodec(), UdpTunnel.relay(destination));
                stream.config().setAutoRead(false);
                // 一次解码同时产出三个报文，刻意暂不触发 readComplete，确保覆盖同轮发送顺序。
                stream.pipeline().fireChannelRead(Unpooled.wrappedBuffer(new byte[]{0, 3, 1, 2, 3, 0, 0, 0, 2, 4, 5}));
                return stream;
            }).sync().getNow();
            for (byte[] expected : List.of(new byte[]{1, 2, 3}, new byte[0], new byte[]{4, 5})) {
                var packet = new DatagramPacket(new byte[16], 16);
                origin.receive(packet);
                assertArrayEquals(expected, Arrays.copyOf(packet.getData(), packet.getLength()),
                        "同轮空报文不能越过此前的非空报文");
            }
            EmbeddedChannel stream = source;
            group.next().submit(() -> stream.pipeline().fireChannelReadComplete()).sync();
            assertTrue(peer.isActive());
        } finally {
            if (source != null) {
                EmbeddedChannel stream = source;
                group.next().submit(() -> {
                    stream.finishAndReleaseAll();
                }).sync();
            }
            if (peer != null) peer.close().sync();
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }
}
