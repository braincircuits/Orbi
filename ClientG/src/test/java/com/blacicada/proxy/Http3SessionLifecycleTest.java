package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.OutboundNetwork;
import com.blacicada.common.ProxyConfig;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(15)
class Http3SessionLifecycleTest {
    @Test
    void cancellingDuringHandshakeImmediatelyReleasesLocalStreamCapacity() throws Exception {
        var group = OutboundNetwork.DEFAULT.newGroup();
        var loop = group.next();
        var resolver = OutboundNetwork.DEFAULT.resolver();
        // 真实 UDP 端口持续收包但不回答，保证共享握手仍未结束。
        try (var blackhole = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            blackhole.setSoTimeout(3000);
            var values = new Properties();
            values.setProperty("password", "lifecycle-test");
            values.setProperty("server.host", "127.0.0.1");
            values.setProperty("server.port", Integer.toString(blackhole.getLocalPort()));
            values.setProperty("connectTimeoutMillis", "10000");
            values.setProperty("maxStreams", "1");
            try (var session = new Http3Session(loop, new ProxyConfig(values, Path.of(".")), resolver)) {
                var target = new Authority("example.test", 443);
                var first = session.open(target);
                blackhole.receive(new DatagramPacket(new byte[2048], 2048));
                assertTrue(first.cancel(false));
                // 事件循环屏障确保取消回调已完成，避免用线程延时猜测时序。
                loop.submit(() -> {
                }).sync();
                for (int i = 0; i < 3; i++) {
                    var next = session.open(target);
                    loop.submit(() -> {
                    }).sync();
                    assertFalse(next.isDone(), "取消握手期间的请求后，新请求应继续等待共享握手，不能被本地额度拒绝");
                    assertTrue(next.cancel(false));
                    loop.submit(() -> {
                    }).sync();
                }
                assertEquals(0, session.connectionCount());
            }
        } finally {
            resolver.close();
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
