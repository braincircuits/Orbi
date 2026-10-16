package com.blacicada.common;

import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.embedded.EmbeddedChannel;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class UdpTunnelTest {
    @ParameterizedTest @ValueSource(booleans = {false, true})
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
                group.next().submit(() -> { stream.finishAndReleaseAll(); }).sync();
            }
            if (peer != null) peer.close().sync();
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync();
        }
    }
}
