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
        assertEquals(0L, traffic.snapshot().get("sentBytes"));
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
            var snapshot = traffic.snapshot();
            assertEquals(300L, snapshot.get("sentBytes")); assertEquals(600L, snapshot.get("receivedBytes"));
            assertEquals(150.0, snapshot.get("sendBytesPerSecond")); assertEquals(300.0, snapshot.get("receiveBytesPerSecond"));
            assertEquals(12_000L, snapshot.get("sampledAt"));
            nanos.addAndGet(1_000_000_000L); traffic.sample();
            assertEquals(0.0, traffic.snapshot().get("sendBytesPerSecond"));
            traffic.stop();
            assertEquals(600L, traffic.snapshot().get("receivedBytes"));
            var stopped = traffic.snapshot(); traffic.sample(); assertEquals(stopped, traffic.snapshot());
        } finally { sent.release(); received.release(); channel.finishAndReleaseAll(); }
    }
    @Test void rateSnapshotsAreImmutableAndDoNotRetainSecondHistory() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 10_000L);
        var initial = traffic.snapshot();
        nanos.addAndGet(4_000_000_000L); traffic.sample();
        assertEquals(14_000L, traffic.snapshot().get("sampledAt"));
        assertEquals(10_000L, initial.get("sampledAt"));
        assertFalse(initial.containsKey("history"));
        assertThrows(UnsupportedOperationException.class, initial::clear);
    }
    @Test void minutesFollowByteArrivalAndFlushOnlyAtBoundaryOrStop() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 40_000L);
        var minutes = new java.util.ArrayList<Map<String, Object>>();
        traffic.recordTo(minutes::add);
        var channel = new EmbeddedChannel(traffic.handler());
        try {
            nanos.set(19_900_000_000L);
            channel.writeOutbound(Unpooled.wrappedBuffer(new byte[100]));
            traffic.sample();
            assertTrue(minutes.isEmpty(), "秒级采样不应写历史表");
            nanos.set(20_000_000_000L);
            channel.writeInbound(Unpooled.wrappedBuffer(new byte[500]));
            assertEquals(1, minutes.size());
            assertEquals(Map.of("sessionId", traffic.sessionId(), "minuteStart", 0L,
                    "activeDurationMillis", 20_000L, "sentBytes", 100L, "receivedBytes", 0L), minutes.getFirst());
            nanos.set(35_000_000_000L); traffic.stop(); traffic.stop();
            assertEquals(2, minutes.size());
            assertEquals(60_000L, minutes.getLast().get("minuteStart"));
            assertEquals(15_000L, minutes.getLast().get("activeDurationMillis"));
            assertEquals(500L, minutes.getLast().get("receivedBytes"));
            assertEquals(100L, traffic.snapshot().get("sentBytes"));
            assertEquals(500L, traffic.snapshot().get("receivedBytes"));
        } finally { channel.finishAndReleaseAll(); }
    }
    @Test void delayedSamplerKeepsZeroTrafficMinutesAndExactBoundaryStopHasNoExtraRow() {
        var nanos = new AtomicLong();
        var traffic = new TrafficStatistics(nanos::get, () -> 0L);
        var minutes = new java.util.ArrayList<Map<String, Object>>();
        traffic.recordTo(minutes::add);
        nanos.set(180_000_000_000L); traffic.stop();
        assertEquals(3, minutes.size());
        assertEquals(List.of(0L, 60_000L, 120_000L), minutes.stream().map(m -> m.get("minuteStart")).toList());
        for (var minute : minutes) {
            assertEquals(60_000L, minute.get("activeDurationMillis"));
            assertEquals(0L, minute.get("sentBytes")); assertEquals(0L, minute.get("receivedBytes"));
        }
    }

}
