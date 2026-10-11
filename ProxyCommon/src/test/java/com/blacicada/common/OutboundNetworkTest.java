package com.blacicada.common;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.kqueue.KQueueSocketChannel;
import io.netty.channel.unix.Socket;
import org.junit.jupiter.api.*;
import java.net.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class OutboundNetworkTest {
    @Test void udpUsesResolvedNativeAddressFamily() throws Exception {
        var network = OutboundNetwork.DEFAULT;
        var group = network.newGroup(); var resolver = network.resolver();
        try {
            for (String host : new String[]{"127.0.0.1", "::1"}) {
                var channel = UdpTunnel.connect(group.next(), resolver,
                        InetSocketAddress.createUnresolved(host, 12345)).sync().getNow();
                try {
                    // 检查真实绑定地址族，防止 IPv4 回包再次落入共用端口的其他应用。
                    assertEquals(InetAddress.getByName(host).getClass(),
                            ((InetSocketAddress) channel.localAddress()).getAddress().getClass());
                } finally { channel.close().sync(); }
            }
        } finally { resolver.close(); group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync(); }
    }

    @Test void macosSocketsBindBothFamiliesAndPreserveEmptyUdp() throws Exception {
        Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        int index = NetworkInterface.getByName("lo0").getIndex();
        var network = new OutboundNetwork(index);
        var tcp = (KQueueSocketChannel) network.tcp();
        try {
            var fd = (Socket) tcp.fd();
            assertEquals(index, fd.getIntOpt(41, 125));
        } finally { tcp.unsafe().closeForcibly(); }
        var group = network.newGroup(); var resolver = network.resolver();
        try {
          for (String host : new String[]{"127.0.0.1", "::1"}) try (var origin = new DatagramSocket(new InetSocketAddress(host, 0))) {
            origin.setSoTimeout(3000);
            var channel = UdpTunnel.connect(group.next(), resolver, new InetSocketAddress(host, origin.getLocalPort()), network).sync().getNow();
            var fd = (Socket) ((io.netty.channel.kqueue.KQueueDatagramChannel) channel).fd();
            assertEquals(index, fd.getIntOpt(host.contains(":") ? 41 : 0, host.contains(":") ? 125 : 25));
            var replies = new LinkedBlockingQueue<byte[]>();
            channel.pipeline().addLast(new SimpleChannelInboundHandler<ByteBuf>() {
                @Override protected void channelRead0(ChannelHandlerContext ctx, ByteBuf data) {
                    byte[] bytes = new byte[data.readableBytes()]; data.readBytes(bytes); replies.add(bytes); ctx.read();
                }
            });
            channel.read();
            for (byte[] data : new byte[][]{new byte[0], new byte[]{1, 2, 3}}) {
                channel.writeAndFlush(Unpooled.wrappedBuffer(data)).sync();
                var packet = new DatagramPacket(new byte[10], 10); origin.receive(packet);
                assertEquals(data.length, packet.getLength()); origin.send(packet);
                assertArrayEquals(data, replies.poll(3, TimeUnit.SECONDS));
            }
            channel.close().sync();
          }
        } finally { resolver.close(); group.shutdownGracefully(0, 1, TimeUnit.SECONDS).sync(); }
    }
}
