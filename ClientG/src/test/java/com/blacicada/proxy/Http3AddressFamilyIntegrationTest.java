package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.OutboundNetwork;
import com.blacicada.common.ProxyConfig;
import com.blacicada.h3.Http3ProxyServer;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.nio.file.Path;
import java.util.Properties;
import java.util.ArrayList;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class Http3AddressFamilyIntegrationTest {
    private String resource(String name) throws Exception {
        return Path.of(getClass().getResource("/tls/" + name).toURI()).toString();
    }

    static Stream<Arguments> addresses() throws Exception {
        var cases = new ArrayList<Arguments>();
        for (String host : new String[]{"127.0.0.1", "::1"}) {
            cases.add(Arguments.of(host, 0));
            if (System.getProperty("os.name").startsWith("Mac"))
                cases.add(Arguments.of(host, NetworkInterface.getByName("lo0").getIndex()));
        }
        return cases.stream();
    }

    @ParameterizedTest @MethodSource("addresses")
    void handshakeAndReconnectUseResolvedAddressFamily(String host, int interfaceIndex) throws Exception {
        var network = new OutboundNetwork(interfaceIndex);
        var group = network.newGroup();
        var resolver = network.resolver();
        var values = new Properties();
        values.setProperty("password", "address-family-test");
        values.setProperty("bind", host); values.setProperty("port", "0");
        values.setProperty("tls.cert", resource("localhost.crt"));
        values.setProperty("tls.key", resource("localhost.key"));
        try (var origin = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
             var server = new Http3ProxyServer(new ProxyConfig(values, Path.of("."))).start()) {
            origin.setSoTimeout(3000);
            values.setProperty("server.host", host);
            values.setProperty("server.port", Integer.toString(server.address().getPort()));
            values.setProperty("tls.ca", resource("localhost.crt"));
            values.setProperty("tls.serverName", "localhost");
            values.setProperty("connectTimeoutMillis", "3000");
            try (var session = new Http3Session(group.next(), new ProxyConfig(values, Path.of(".")), resolver, network)) {
                for (int attempt = 0; attempt < 2; attempt++) {
                    var opening = session.open(new Authority("127.0.0.1", origin.getLocalPort()), false);
                    var stream = opening.get(4, TimeUnit.SECONDS);
                    try (var accepted = origin.accept()) {
                        // 检查承载 QUIC 的真实 UDP 绑定地址，而非已经转换成 IPv4 的对端地址。
                        // 旧实现的 IPv6 通配绑定会与 macOS 已占用的 IPv4 端口重叠，导致回包丢失。
                        var local = (InetSocketAddress) stream.parent().parent().localAddress();
                        assertEquals(InetAddress.getByName(host).getClass(), local.getAddress().getClass());
                        var connectionClosed = stream.parent().closeFuture();
                        server.disconnectClients();
                        assertTrue(connectionClosed.await(3, TimeUnit.SECONDS), "服务端断开后客户端必须收到关闭通知");
                    }
                }
                assertEquals(2, session.connectionCount(), "重新握手仍需使用正确地址族");
            }
        } finally {
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
