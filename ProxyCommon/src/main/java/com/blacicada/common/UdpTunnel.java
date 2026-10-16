package com.blacicada.common;

import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.channel.socket.DatagramPacket;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.handler.timeout.IdleStateEvent;
import io.netty.handler.timeout.IdleStateHandler;
import io.netty.resolver.dns.DnsAddressResolverGroup;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.util.List;

/** 本项目的 UDP CONNECT 握手、报文边界和目标套接字。 */
public final class UdpTunnel {
    public static final String HEADER = "x-network-transport";
    public static final String VALUE = "udp";
    // 按关联回收空闲资源；不受其他 CONNECT 流上的流量影响。
    public static final int IDLE_SECONDS = 60;

    private UdpTunnel() {}

    /** 缺省为 TCP；显式提供的标识必须唯一且为 udp。 */
    public static boolean requested(List<? extends CharSequence> values) {
        if (values.isEmpty()) return false;
        if (values.size() == 1 && VALUE.contentEquals(values.getFirst())) return true;
        throw new IllegalArgumentException("UDP 隧道标识无效");
    }

    public static void addFraming(ChannelPipeline pipeline) {
        pipeline.addLast("udpFrames", new UdpFrameCodec());
        pipeline.addLast("udpIdle", new IdleStateHandler(0, 0, IDLE_SECONDS));
    }

    public static io.netty.util.concurrent.Future<Channel> connect(EventLoop loop, DnsAddressResolverGroup resolver, InetSocketAddress address) {
        return connect(loop, resolver, address, OutboundNetwork.DEFAULT);
    }
    public static io.netty.util.concurrent.Future<Channel> connect(EventLoop loop, DnsAddressResolverGroup resolver, InetSocketAddress address, OutboundNetwork network) {
        var result = loop.<Channel>newPromise();
        var resolution = resolver.getResolver(loop).resolve(address);
        result.addListener(done -> { if (done.isCancelled()) resolution.cancel(false); });
        resolution.addListener(resolved -> {
            if (result.isDone()) return;
            if (!resolved.isSuccess()) { result.tryFailure(resolved.cause()); return; }
            var connecting = connectResolved(loop, resolution.getNow(), network);
            result.addListener(done -> { if (!done.isSuccess()) connecting.channel().close(); });
            connecting.addListener((ChannelFutureListener) connected -> {
                if (!connected.isSuccess()) {
                    connected.channel().close(); result.tryFailure(connected.cause());
                } else if (!result.trySuccess(connected.channel())) connected.channel().close();
            });
        });
        return result;
    }

    private static ChannelFuture connectResolved(EventLoop loop, InetSocketAddress address, OutboundNetwork network) {
        boolean ipv4 = address.getAddress() instanceof java.net.Inet4Address;
        return new Bootstrap().group(loop).channelFactory(() -> {
            try {
                // 必须在解析后选择原生地址族；macOS 上双栈通配端口可能与 IPv4 套接字重叠。
                var socket = network.bound() ? null : DatagramChannel.open(
                        ipv4 ? java.net.StandardProtocolFamily.INET : java.net.StandardProtocolFamily.INET6);
                io.netty.channel.socket.DatagramChannel channel = socket == null ? network.udp(ipv4
                        ? io.netty.channel.socket.InternetProtocolFamily.IPv4
                        : io.netty.channel.socket.InternetProtocolFamily.IPv6) : new NioDatagramChannel(socket);
                channel.pipeline().addLast("datagram", new ChannelDuplexHandler() {
                    private InetSocketAddress target;
                    @Override public void connect(ChannelHandlerContext ctx, SocketAddress remote, SocketAddress local, ChannelPromise promise) {
                        target = (InetSocketAddress) remote;
                        // JDK 已连接的 DatagramChannel 也会跳过空报文，因此绑定套接字并显式限定收发目标。
                        ctx.bind(local == null ? new InetSocketAddress(ipv4 ? "0.0.0.0" : "::", 0) : local, promise);
                    }
                    @Override public void channelRead(ChannelHandlerContext ctx, Object message) {
                        var packet = (DatagramPacket) message;
                        if (!packet.sender().equals(target)) { packet.release(); ctx.read(); return; }
                        ByteBuf payload = packet.content().retain();
                        packet.release();
                        ctx.fireChannelRead(payload);
                    }
                    @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
                        // Netty 的 NIO 通道会跳过空 ByteBuf，空 UDP 报文需实际调用底层套接字发送。
                        if (message instanceof ByteBuf payload && !payload.isReadable()) {
                            payload.release();
                            try {
                                if (socket != null) socket.send(ByteBuffer.allocate(0), target);
                                else ((io.netty.channel.unix.Socket) ((io.netty.channel.kqueue.KQueueDatagramChannel) channel).fd())
                                        .sendTo(ByteBuffer.allocateDirect(0), 0, 0, target.getAddress(), target.getPort());
                                promise.setSuccess();
                            }
                            catch (Exception e) { promise.setFailure(e); }
                        } else if (message instanceof ByteBuf payload) ctx.write(new DatagramPacket(payload, target), promise);
                        else ctx.write(message, promise);
                    }
                });
                return channel;
            } catch (java.io.IOException e) { throw new ChannelException("创建 UDP 套接字失败", e); }
        }).option(ChannelOption.AUTO_READ, false)
                .option(ChannelOption.SO_SNDBUF, 128 * 1024)
                .option(ChannelOption.RCVBUF_ALLOCATOR, new FixedRecvByteBufAllocator(65536))
                .option(ChannelOption.WRITE_BUFFER_WATER_MARK, Transport.WATERMARK)
                .handler(new ChannelInboundHandlerAdapter()).connect(address);
    }

    /** UDP 关联没有 TCP 半关闭语义，任一方向结束或空闲即释放两端资源。 */
    public static RelayHandler relay(Channel peer) {
        return new RelayHandler(peer) {
            @Override public void channelRead(ChannelHandlerContext ctx, Object message) {
                super.channelRead(ctx, message);
                // 空 UDP 直接调用底层套接字；逐报文刷新，避免越过此前尚未刷新的非空报文。
                peer.flush();
            }
            @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
                if (event == ChannelInputShutdownEvent.INSTANCE || event instanceof IdleStateEvent) {
                    peer.close(); ctx.close();
                } else ctx.fireUserEventTriggered(event);
            }
            @Override public void channelInactive(ChannelHandlerContext ctx) {
                peer.close(); ctx.fireChannelInactive();
            }
        };
    }
}
