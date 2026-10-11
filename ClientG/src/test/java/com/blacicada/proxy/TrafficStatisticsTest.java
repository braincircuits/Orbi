package com.blacicada.proxy;

import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.channel.*;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import static org.junit.jupiter.api.Assertions.*;

class TrafficStatisticsTest {
    @Test void failedWritesDoNotIncreaseSentBytes() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 10_000L);
        var channel = new EmbeddedChannel(new ChannelOutboundHandlerAdapter() {
            @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) {
                ReferenceCountUtil.release(message); promise.setFailure(new java.io.IOException("测试写入失败"));
            }
        }, traffic.handler());
        var future = channel.writeAndFlush(Unpooled.wrappedBuffer(new byte[100]));
        assertFalse(future.isSuccess());
        nanos.set(1_000_000_000L); traffic.sample();
        assertEquals(0L, traffic.snapshot(false).get("sentBytes"));
        channel.finishAndReleaseAll();
    }
    @Test void countsOnceWithoutChangingBuffersAndUsesElapsedTime() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 10_000L);
        var channel = new EmbeddedChannel(traffic.handler());
        var sent = Unpooled.wrappedBuffer(new byte[300]);
        var received = Unpooled.wrappedBuffer(new byte[600]);
        try {
            channel.writeOutbound(sent); channel.writeInbound(received);
            assertSame(sent, channel.readOutbound()); assertSame(received, channel.readInbound());
            nanos.set(2_000_000_000L); traffic.sample();
            var snapshot = traffic.snapshot(true);
            assertEquals(300L, snapshot.get("sentBytes")); assertEquals(600L, snapshot.get("receivedBytes"));
            assertEquals(150.0, snapshot.get("sendBytesPerSecond")); assertEquals(300.0, snapshot.get("receiveBytesPerSecond"));
            assertEquals(12_000L, snapshot.get("sampledAt"));
            nanos.addAndGet(1_000_000_000L); traffic.sample();
            assertEquals(0.0, traffic.snapshot(false).get("sendBytesPerSecond"));
            traffic.stop();
            assertEquals(600L, traffic.snapshot(false).get("receivedBytes"));
            var stopped = traffic.snapshot(true); traffic.sample(); assertEquals(stopped, traffic.snapshot(true));
        } finally { sent.release(); received.release(); channel.finishAndReleaseAll(); }
    }
    @Test void keepsOnlyFiveMinutesAndSnapshotsAreImmutable() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 10_000L);
        var initial = traffic.snapshot(true);
        for (int i = 0; i < 700; i++) { nanos.addAndGet(1_000_000_000L); traffic.sample(); }
        var history = (List<?>) traffic.snapshot(true).get("history");
        assertEquals(301, history.size());
        assertEquals(410_000L, ((Map<?, ?>) history.getFirst()).get("sampledAt"));
        assertEquals(1, ((List<?>) initial.get("history")).size());
        assertThrows(UnsupportedOperationException.class, history::clear);
        assertNotEquals(initial.get("sessionId"), new TrafficStatistics().snapshot(false).get("sessionId"));
    }
}
