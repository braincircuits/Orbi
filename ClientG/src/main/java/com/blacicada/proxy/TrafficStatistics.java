package com.blacicada.proxy;

import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import java.util.*;
import java.util.concurrent.atomic.LongAdder;
import java.util.function.LongSupplier;

/** 统计业务流中的字节，不包含本地 CONNECT 握手、代理协议帧和传输层开销。 */
public final class TrafficStatistics {
    private final LongAdder sent = new LongAdder(), received = new LongAdder();
    private final LongSupplier nanoClock;
    private final String sessionId = UUID.randomUUID().toString();
    private final long startedAt;
    private long previousNanos, previousSent, previousReceived;
    private final ArrayDeque<Map<String, Object>> history = new ArrayDeque<>();
    private Map<String, Object> current;
    private boolean stopped;
    private java.util.function.Consumer<Map<String, Object>> recorder;
    String sessionId() { return sessionId; }
    synchronized void recordTo(java.util.function.Consumer<Map<String, Object>> recorder) {
        this.recorder = recorder;
        if (recorder != null) recorder.accept(snapshot(false));
    }

    public TrafficStatistics() { this(System::nanoTime, System::currentTimeMillis); }
    TrafficStatistics(LongSupplier nanoClock, LongSupplier wallClock) {
        this.nanoClock = nanoClock;
        startedAt = wallClock.getAsLong(); previousNanos = nanoClock.getAsLong();
        current = point(startedAt, 0, 0, 0, 0);
        history.add(current);
    }
    private Map<String, Object> point(long time, long send, long receive, double upload, double download) {
        return Map.of("sampledAt", time, "sentBytes", send, "receivedBytes", receive,
                "sendBytesPerSecond", upload, "receiveBytesPerSecond", download);
    }
    /** 在目标套接字或解码后的代理业务流上安装，每个业务连接仅安装一次。 */
    ChannelHandler handler() {
        return new ChannelDuplexHandler() {
            @Override public void channelRead(ChannelHandlerContext ctx, Object message) throws Exception {
                if (message instanceof ByteBuf bytes) received.add(bytes.readableBytes());
                super.channelRead(ctx, message);
            }
            @Override public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) throws Exception {
                int bytes = message instanceof ByteBuf buffer ? buffer.readableBytes() : 0;
                // 写失败不记为已发送；在提交前记录长度，避免缓冲区被释放后再次读取。
                ChannelPromise completion = promise.unvoid();
                if (bytes > 0) completion.addListener(done -> { if (done.isSuccess()) sent.add(bytes); });
                super.write(ctx, message, completion);
            }
        };
    }
    public synchronized void sample() { sample(false); }
    public synchronized void stop() { if (!stopped) { sample(true); stopped = true; } }
    private void sample(boolean ending) {
        if (stopped) return;
        long now = nanoClock.getAsLong(), elapsed = now - previousNanos;
        if (elapsed <= 0 && !ending) return;
        long upload = sent.sum(), download = received.sum();
        double seconds = elapsed / 1_000_000_000.0;
        // 时间轴使用单调时钟推进，系统时间校准不会产生倒序样本。
        long time = ((Number) current.get("sampledAt")).longValue() + Math.max(1, elapsed / 1_000_000);
        current = point(time, upload, download,
                ending || seconds <= 0 ? 0 : (upload - previousSent) / seconds,
                ending || seconds <= 0 ? 0 : (download - previousReceived) / seconds);
        previousNanos = now; previousSent = upload; previousReceived = download;
        history.add(current);
        while (history.size() > 301 || history.size() > 1
                && ((Number) history.getFirst().get("sampledAt")).longValue() < time - 300_000) history.removeFirst();
        if (recorder != null) recorder.accept(snapshot(false));
    }
    public synchronized Map<String, Object> snapshot(boolean includeHistory) {
        var result = new LinkedHashMap<String, Object>(current);
        result.put("sessionId", sessionId); result.put("startedAt", startedAt);
        if (includeHistory) result.put("history", List.copyOf(history));
        return Collections.unmodifiableMap(result);
    }
    public static Map<String, Object> empty(boolean includeHistory) {
        var result = new LinkedHashMap<String, Object>();
        result.put("sessionId", ""); result.put("startedAt", 0L); result.put("sampledAt", 0L);
        result.put("sentBytes", 0L); result.put("receivedBytes", 0L);
        result.put("sendBytesPerSecond", 0.0); result.put("receiveBytesPerSecond", 0.0);
        if (includeHistory) result.put("history", List.of());
        return result;
    }
}
