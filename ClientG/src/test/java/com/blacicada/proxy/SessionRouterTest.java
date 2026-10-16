package com.blacicada.proxy;

import com.blacicada.common.OutboundNetwork;
import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(20)
class SessionRouterTest {
    @TempDir
    Path directory;

    @Test
    void statusReadsRemainSafeWhileSwitchingBetweenDirectAndProxy() throws Exception {
        Properties connection = new Properties();
        connection.setProperty("protocol", "http2");
        connection.setProperty("server.host", "localhost");
        connection.setProperty("password", "测试密码");
        var profile = new KernelConfig.Profile("test", "测试节点", new ProxyConfig(connection, directory));
        Properties directOptions = new Properties();
        directOptions.setProperty("routingMode", "direct");
        var direct = new KernelConfig(new ProxyConfig(directOptions, directory), List.of(profile), profile.id());
        var proxy = new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(profile), profile.id());
        var group = OutboundNetwork.DEFAULT.newGroup();
        var resolver = OutboundNetwork.DEFAULT.resolver();
        AtomicBoolean reading = new AtomicBoolean(true);
        CountDownLatch started = new CountDownLatch(1);
        try (var router = new SessionRouter(group.next(), resolver, direct, OutboundNetwork.DEFAULT);
             var reader = Executors.newSingleThreadExecutor()) {
            var status = reader.submit(() -> {
                started.countDown();
                while (reading.get()) {
                    assertEquals(0, router.connectionCount());
                    assertTrue(Set.of("idle", "unused").contains(router.connectionState()));
                    assertEquals("", router.lastError());
                }
            });
            try {
                assertTrue(started.await(2, TimeUnit.SECONDS));
                // 模拟控制线程查询状态与事件循环切换会话同时发生，不建立真实服务端连接。
                for (int i = 0; i < 300; i++) {
                    router.apply(proxy, () -> {
                    });
                    router.apply(direct, () -> {
                    });
                }
            } finally {
                reading.set(false);
            }
            status.get(2, TimeUnit.SECONDS);
        } finally {
            resolver.close();
            group.shutdownGracefully(0, 2, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
