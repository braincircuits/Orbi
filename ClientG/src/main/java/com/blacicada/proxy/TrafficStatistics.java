package com.blacicada.proxy;

import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import java.util.*;
import java.util.function.LongSupplier;

/** 统计业务流中的字节，不包含本地 CONNECT 握手、代理协议帧和传输层开销。 */
public final class TrafficStatistics {
    private long sent, received;
    private final LongSupplier nanoClock;
    private final String sessionId = UUID.randomUUID().toString();
    private final long startedAt;
    private final long startedNanos;
    private long previousNanos, previousSent, previousReceived;
    private long minuteStart, minuteUpdatedAt, minuteDuration, minuteSent, minuteReceived;
    private Map<String, Object> current;
    private boolean stopped;
    private java.util.function.Consumer<Map<String, Object>> recorder;
    String sessionId() { return sessionId; }
    synchronized void recordTo(java.util.function.Consumer<Map<String, Object>> recorder) {
        this.recorder = recorder;
    }

    public TrafficStatistics() { this(System::nanoTime, System::currentTimeMillis); }
    TrafficStatistics(LongSupplier nanoClock, LongSupplier wallClock) {
        this.nanoClock = nanoClock;
        startedAt = wallClock.getAsLong(); previousNanos = nanoClock.getAsLong();
        startedNanos = previousNanos;
        minuteStart = Math.floorDiv(startedAt, 60_000) * 60_000;
        minuteUpdatedAt = startedAt;
        current = point(startedAt, 0, 0, 0, 0);
    }
    private Map<String, Object> point(long time, long send, long receive, double upload, double download) {
        return Map.of("sampledAt", time, "sentBytes", send, "receivedBytes", receive,
                "sendBytesPerSecond", upload, "receiveBytesPerSecond", download);
    }
    /** 在目标套接字或解码后的代理业务流上安装，每个业务连接仅安装一次。 */
    ChannelHandler handler() {
        return new ChannelDuplexHandler() {
            @Override public void channelRead(ChannelHandlerContext ctx, Object message) throws Exception {
                if (message instanceof ByteBuf bytes) recordBytes(0, bytes.readableBytes());
                super.channelRead(ctx, message);
            }
            @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
                int bytes = message instanceof ByteBuf buffer ? buffer.readableBytes() : 0;
                // 写失败不记为已发送；在提交前记录长度，避免缓冲区被释放后再次读取。
                ChannelPromise completion = promise.unvoid();
                if (bytes > 0) completion.addListener(done -> { if (done.isSuccess()) recordBytes(bytes, 0); });
                super.write(ctx, message, completion);
            }
        };
    }
    /** 在实际读写完成时归属自然分钟，避免跨分钟采样把前一分钟的字节记到下一分钟。 */
    private synchronized void recordBytes(long upload, long download) {
        if (stopped) return;
        advanceMinute(time(nanoClock.getAsLong()));
        sent += upload; received += download;
        minuteSent += upload; minuteReceived += download;
    }
    private long time(long nanos) { return startedAt + Math.max(0, (nanos - startedNanos) / 1_000_000); }
    private void advanceMinute(long time) {
        while (time >= minuteStart + 60_000) {
            minuteDuration += minuteStart + 60_000 - minuteUpdatedAt;
            recordMinute();
            minuteStart += 60_000; minuteUpdatedAt = minuteStart;
            minuteDuration = 0; minuteSent = 0; minuteReceived = 0;
        }
        minuteDuration += time - minuteUpdatedAt;
        minuteUpdatedAt = time;
    }
    private void recordMinute() {
        if (recorder != null && (minuteDuration > 0 || minuteSent > 0 || minuteReceived > 0))
            recorder.accept(Map.of("sessionId", sessionId, "minuteStart", minuteStart,
                    "activeDurationMillis", minuteDuration, "sentBytes", minuteSent, "receivedBytes", minuteReceived));
    }
    public synchronized void sample() { sample(false); }
    public synchronized void stop() { if (!stopped) { sample(true); stopped = true; } }
    private void sample(boolean ending) {
        if (stopped) return;
        long now = nanoClock.getAsLong(), elapsed = now - previousNanos;
        if (elapsed <= 0 && !ending) return;
        long upload = sent, download = received;
        double seconds = elapsed / 1_000_000_000.0;
        // 时间轴使用单调时钟推进，系统时间校准不会产生倒序样本。
        long time = time(now);
        advanceMinute(time);
        if (ending) recordMinute();
        current = point(time, upload, download,
                ending || seconds <= 0 ? 0 : (upload - previousSent) / seconds,
                ending || seconds <= 0 ? 0 : (download - previousReceived) / seconds);
        previousNanos = now; previousSent = upload; previousReceived = download;

    }
    public synchronized Map<String, Object> snapshot() {
        var result = new LinkedHashMap<String, Object>(current);
        result.put("sessionId", sessionId); result.put("startedAt", startedAt);
        return Collections.unmodifiableMap(result);
    }
    public static Map<String, Object> empty() {
        var result = new LinkedHashMap<String, Object>();
        result.put("sessionId", ""); result.put("startedAt", 0L); result.put("sampledAt", 0L);
        result.put("sentBytes", 0L); result.put("receivedBytes", 0L);
        result.put("sendBytesPerSecond", 0.0); result.put("receiveBytesPerSecond", 0.0);
        return result;
    }
}
