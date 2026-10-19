package com.blacicada.proxy;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.util.concurrent.DefaultPromise;
import io.netty.util.concurrent.ImmediateEventExecutor;
import org.junit.jupiter.api.Test;

import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class TunTlsRouterTest {
    private byte[] hello(String domain) throws Exception {
        var engine = SSLContext.getDefault().createSSLEngine();
        engine.setUseClientMode(true);
        var parameters = engine.getSSLParameters();
        parameters.setServerNames(domain == null ? List.of() : List.of(new SNIHostName(domain)));
        engine.setSSLParameters(parameters);
        engine.beginHandshake();
        var output = ByteBuffer.allocate(32768);
        engine.wrap(ByteBuffer.allocate(0), output);
        return java.util.Arrays.copyOf(output.array(), output.position());
    }

    @Test
    void fragmentedHelloWaitsForOutboundAndPreservesEveryByte() throws Exception {
        byte[] original = hello("www.baidu.com");
        var ready = new DefaultPromise<Void>(ImmediateEventExecutor.INSTANCE);
        var names = new ArrayList<String>();
        var channel = new EmbeddedChannel(new TunTlsRouter(domain -> { names.add(domain); return ready; },
                () -> { fail("存在 SNI 时不应读取 DNS 关联"); return "stale.example"; }));
        try {
            for (byte value : original) channel.writeInbound(Unpooled.wrappedBuffer(new byte[]{value}));
            assertEquals(List.of("www.baidu.com"), names);
            assertNull(channel.readInbound(), "出站未就绪前不能丢失或提前转发握手");
            ready.setSuccess(null);
            var forwarded = new ByteArrayOutputStream();
            ByteBuf buffer;
            while ((buffer = channel.readInbound()) != null) {
                byte[] bytes = new byte[buffer.readableBytes()];
                buffer.readBytes(bytes); buffer.release(); forwarded.writeBytes(bytes);
            }
            assertArrayEquals(original, forwarded.toByteArray());
        } finally { channel.finishAndReleaseAll(); }
    }

    @Test
    void helloWithoutSniUsesDnsAssociation() throws Exception {
        byte[] original = hello(null);
        var ready = new DefaultPromise<Void>(ImmediateEventExecutor.INSTANCE);
        var names = new ArrayList<String>();
        var channel = new EmbeddedChannel(new TunTlsRouter(domain -> { names.add(domain); return ready; }, () -> "cached.example"));
        try {
            channel.writeInbound(Unpooled.wrappedBuffer(original));
            assertEquals(1, names.size());
            assertEquals("cached.example", names.getFirst());
            ready.setSuccess(null);
        } finally { channel.finishAndReleaseAll(); }
    }

    @Test
    void failedOutboundClosesWithoutForwardingTlsBytes() throws Exception {
        byte[] original = hello("www.baidu.com");
        var ready = new DefaultPromise<Void>(ImmediateEventExecutor.INSTANCE);
        var channel = new EmbeddedChannel(new TunTlsRouter(domain -> ready, () -> null));
        try {
            channel.writeInbound(Unpooled.wrappedBuffer(original));
            ready.setFailure(new java.io.IOException("测试出站连接失败"));
            assertFalse(channel.isActive());
        } finally { channel.finishAndReleaseAll(); }
    }

    @Test
    void silentClientFallsBackOnceAndDoesNotLoseLateHello() throws Exception {
        byte[] original = hello("www.baidu.com");
        var ready = new DefaultPromise<Void>(ImmediateEventExecutor.INSTANCE);
        var names = new ArrayList<String>();
        var channel = new EmbeddedChannel(new TunTlsRouter(domain -> { names.add(domain); return ready; }, () -> "cached.example"));
        try {
            channel.advanceTimeBy(251, java.util.concurrent.TimeUnit.MILLISECONDS);
            channel.runScheduledPendingTasks();
            assertEquals(1, names.size());
            assertEquals("cached.example", names.getFirst(), "等待超时后应使用 DNS 关联");
            channel.writeInbound(Unpooled.wrappedBuffer(original));
            assertEquals(1, names.size(), "迟到的握手不能重复创建出口");
            ready.setSuccess(null);
            ByteBuf forwarded = channel.readInbound();
            try {
                byte[] bytes = new byte[forwarded.readableBytes()];
                forwarded.readBytes(bytes);
                assertArrayEquals(original, bytes);
            } finally { forwarded.release(); }
        } finally { channel.finishAndReleaseAll(); }
    }

    @Test
    void missingSniAndDnsAssociationKeepsOriginalIpRoute() throws Exception {
        byte[] original = hello(null);
        var ready = new DefaultPromise<Void>(ImmediateEventExecutor.INSTANCE);
        var names = new ArrayList<String>();
        var channel = new EmbeddedChannel(new TunTlsRouter(domain -> { names.add(domain); return ready; }, () -> null));
        try {
            channel.writeInbound(Unpooled.wrappedBuffer(original));
            assertEquals(1, names.size());
            assertNull(names.getFirst());
            ready.setSuccess(null);
        } finally { channel.finishAndReleaseAll(); }
    }
}
