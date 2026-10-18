package com.blacicada.common;

import io.netty.channel.*;
import io.netty.channel.kqueue.*;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.*;
import io.netty.channel.socket.nio.*;
import io.netty.channel.unix.IntegerUnixChannelOption;
import io.netty.resolver.dns.*;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.StandardProtocolFamily;

/**
 * 将 TUN 内核的所有出站套接字约束到真实接口，避免再次进入虚拟网卡。
 */
public final class OutboundNetwork {
    public static final OutboundNetwork DEFAULT = new OutboundNetwork(0);
    private static final IntegerUnixChannelOption IPV4_INTERFACE = new IntegerUnixChannelOption("network.IP_BOUND_IF", 0, 25);
    private static final IntegerUnixChannelOption IPV6_INTERFACE = new IntegerUnixChannelOption("network.IPV6_BOUND_IF", 41, 125);
    private final int interfaceIndex;
    private final boolean windows = System.getProperty("os.name").startsWith("Windows");

    public OutboundNetwork(int interfaceIndex) {
        if (interfaceIndex < 0) throw new IllegalArgumentException("出口接口索引无效");
        if (interfaceIndex > 0) {
            if (!windows && !System.getProperty("os.name").startsWith("Mac"))
                throw new IllegalArgumentException("TUN 出口绑定仅支持 macOS 和 Windows");
            if (!windows) KQueue.ensureAvailability();
        }
        this.interfaceIndex = interfaceIndex;
    }

    public boolean bound() {
        return interfaceIndex > 0;
    }

    public EventLoopGroup newGroup() {
        return bound() && !windows ? new KQueueEventLoopGroup(1) : new NioEventLoopGroup(1);
    }

    public ServerSocketChannel listener() {
        return bound() && !windows ? new KQueueServerSocketChannel() : new NioServerSocketChannel();
    }

    public SocketChannel tcp() {
        if (bound() && windows) {
            try {
                var channel = java.nio.channels.SocketChannel.open(StandardProtocolFamily.INET6);
                try { WindowsSocketBinding.bind(channel, interfaceIndex, true); return new NioSocketChannel(channel); }
                catch (Throwable failure) { channel.close(); throw failure; }
            } catch (IOException failure) { throw new UncheckedIOException(failure); }
        }
        return protect(bound() ? new KQueueSocketChannel(InternetProtocolFamily.IPv6) : new NioSocketChannel());
    }

    public DatagramChannel udp() {
        if (bound() && windows) return udp(InternetProtocolFamily.IPv6);
        return protect(bound() ? new KQueueDatagramChannel(InternetProtocolFamily.IPv6) : new NioDatagramChannel());
    }

    public DatagramChannel udp(InternetProtocolFamily family) {
        if (bound() && windows) {
            try {
                return new NioDatagramChannel(nioUdp(family));
            } catch (IOException failure) { throw new UncheckedIOException(failure); }
        }
        return protect(bound() ? new KQueueDatagramChannel(family) : new NioDatagramChannel(family), family == InternetProtocolFamily.IPv6);
    }

    java.nio.channels.DatagramChannel nioUdp(InternetProtocolFamily family) throws IOException {
        var channel = java.nio.channels.DatagramChannel.open(family == InternetProtocolFamily.IPv6 ? StandardProtocolFamily.INET6 : StandardProtocolFamily.INET);
        try {
            if (bound()) WindowsSocketBinding.bind(channel, interfaceIndex, family == InternetProtocolFamily.IPv6);
            return channel;
        } catch (Throwable failure) { channel.close(); throw failure; }
    }

    private <C extends Channel> C protect(C channel) {
        return protect(channel, true);
    }

    private <C extends Channel> C protect(C channel, boolean ipv6) {
        if (!bound()) return channel;
        try {
            // 出口选项与原生套接字地址族一致；双栈 TCP 与 DNS 仍使用 IPv6 选项。
            if (!channel.config().setOption(ipv6 ? IPV6_INTERFACE : IPV4_INTERFACE, interfaceIndex))
                throw new IllegalStateException("当前套接字不支持出口接口绑定");
            return channel;
        } catch (RuntimeException e) {
            channel.unsafe().closeForcibly();
            throw e;
        }
    }

    public DnsAddressResolverGroup resolver() {
        return new DnsAddressResolverGroup(new DnsNameResolverBuilder()
                .channelFactory(this::udp).socketChannelFactory(this::tcp)
                .nameServerProvider(DnsServerAddressStreamProviders.platformDefault()).queryTimeoutMillis(3000));
    }
}
