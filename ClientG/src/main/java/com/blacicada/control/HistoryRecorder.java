package com.blacicada.control;

import com.blacicada.io.KernelDatabase;

import java.sql.SQLException;
import java.time.*;
import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;

import org.apache.logging.log4j.LogManager;

/**
 * 转发线程累加域名统计及入队分钟流量，由控制线程串行写库；失败批次保留重试。
 */
final class HistoryRecorder {
    private final KernelDatabase database;
    private final ArrayBlockingQueue<Map<String, Object>> queue = new ArrayBlockingQueue<>(65536);
    private final List<Map<String, Object>> pending = new ArrayList<>();
    private final AtomicLong dropped = new AtomicLong();
    private final Map<String, long[]> access = new HashMap<>();
    private List<Map<String, Object>> accessPending = List.of();
    private long accessMinute;
    private String error = "", maintenanceError = "";
    private final Clock clock;
    private long maintainedMinute = Long.MIN_VALUE, nextCleanup, retryAt, writeRetryAt;
    private boolean trafficPending;

    HistoryRecorder(KernelDatabase database) {
        this(database, Clock.systemDefaultZone());
    }

    HistoryRecorder(KernelDatabase database, Clock clock) {
        this.database = database;
        this.clock = clock;
        accessMinute = Math.floorDiv(clock.millis(), 60000);
        maintain();
    }

    void tick() {
        long minute = Math.floorDiv(clock.millis(), 60000);
        if (minute != accessMinute) {
            accessMinute = minute;
            captureAccess();
        }
        if (clock.millis() >= writeRetryAt && flush() && queue.isEmpty() && pending.isEmpty()) maintain();
    }

    private void maintain() {
        long now = clock.millis(), minute = Math.floorDiv(now, 60000);
        if (now < retryAt) return;
        if (!trafficPending && maintainedMinute == minute && now < nextCleanup) return;
        try {
            database.maintainTraffic(now, clock.getZone(), now >= nextCleanup);
            if (now >= nextCleanup) {
                var local = Instant.ofEpochMilli(now).atZone(clock.getZone());
                var next = local.toLocalDate().atTime(3, 0).atZone(clock.getZone());
                if (!next.isAfter(local)) next = local.toLocalDate().plusDays(1).atTime(3, 0).atZone(clock.getZone());
                nextCleanup = next.toInstant().toEpochMilli();
            }
            maintainedMinute = minute;
            trafficPending = false;
            maintenanceError = "";
        } catch (SQLException failure) {
            if (maintenanceError.isEmpty())
                LogManager.getLogger(HistoryRecorder.class).error("流量汇总或过期清理失败，将重试：{}", failure.getClass().getSimpleName());
            maintenanceError = "流量汇总或过期清理失败，请检查数据库连接与权限";
            retryAt = now + 60000;
        }
    }

    void traffic(Map<String, Object> value) {
        offer(value);
    }

    synchronized void access(Map<String, Object> value) {
        String state = (String) value.get("state");
        if (!state.equals("pending") && !state.equals("failed")) return;
        final String host;
        try {
            host = com.blacicada.config.DirectRoutes.normalizeHost(
                    com.blacicada.common.Authority.parse((String) value.get("target"), -1).host());
        } catch (IllegalArgumentException failure) {
            // 统计失败不得中断业务连接，不输出可能包含敏感内容的原始目标。
            if (dropped.incrementAndGet() == 1)
                LogManager.getLogger(HistoryRecorder.class).warn("访问统计目标无效，已跳过该事件");
            return;
        }
        long[] totals = access.computeIfAbsent(host, ignored -> new long[3]);
        if (state.equals("pending")) {
            totals[0]++;
            totals[1] = Math.max(totals[1], ((Number) value.get("createdAt")).longValue());
        } else totals[2] = Math.max(totals[2], ((Number) value.get("completedAt")).longValue());
    }

    private synchronized void captureAccess() {
        if (!accessPending.isEmpty() || access.isEmpty()) return;
        String batch = UUID.randomUUID().toString();
        accessPending = access.entrySet().stream().map(entry -> Map.<String, Object>of("batchId", batch,
                "host", entry.getKey(), "connectionCount", entry.getValue()[0],
                "lastAccessAt", entry.getValue()[1], "lastFailureAt", entry.getValue()[2])).toList();
        access.clear();
    }

    private void offer(Map<String, Object> value) {
        if (!queue.offer(value) && dropped.incrementAndGet() == 1)
            LogManager.getLogger(HistoryRecorder.class).error("历史记录写入队列已满，部分记录未保存，请检查数据库连接与存储空间");
    }

    boolean flush() {
        if (pending.isEmpty()) queue.drainTo(pending, 2048);
        if (pending.isEmpty() && accessPending.isEmpty()) return true;
        try {
            database.writeHistory(pending,
                    accessPending);
            trafficPending |= !pending.isEmpty();
            pending.clear();
            accessPending = List.of();
            error = "";
            return true;
        } catch (SQLException failure) {
            if (error.isEmpty())
                LogManager.getLogger(HistoryRecorder.class).error("历史记录保存失败，将保留待写入批次并重试：{}", failure.getClass().getSimpleName());
            error = "历史记录保存失败，请检查数据库连接、存储空间、权限或占用情况";
            writeRetryAt = clock.millis() + 60000;
            return false;
        }
    }

    void finish() {
        captureAccess();
        while ((!queue.isEmpty() || !pending.isEmpty() || !accessPending.isEmpty()) && flush()) {
            captureAccess();
        }
        if (queue.isEmpty() && pending.isEmpty() && accessPending.isEmpty()) maintain();
    }

    synchronized Map<String, Object> status() {
        return Map.of("pendingRecords", queue.size() + pending.size() + accessPending.size() + access.size(), "droppedRecords", dropped.get(), "error", error.isEmpty() ? maintenanceError : error);
    }
}
