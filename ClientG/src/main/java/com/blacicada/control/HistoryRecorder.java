package com.blacicada.control;

import com.blacicada.io.KernelDatabase;
import java.sql.SQLException;
import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;
import org.apache.logging.log4j.LogManager;

/** 转发线程只入队，由控制线程串行写入数据库；失败批次保留以供重试。 */
final class HistoryRecorder {
    private record Entry(boolean traffic, Map<String, Object> data) { }
    private final KernelDatabase database;
    private final ArrayBlockingQueue<Entry> queue = new ArrayBlockingQueue<>(65536);
    private final List<Entry> pending = new ArrayList<>();
    private final AtomicLong dropped = new AtomicLong();
    private String error = "";
    HistoryRecorder(KernelDatabase database) { this.database = database; }
    void traffic(Map<String, Object> value) { offer(new Entry(true, value)); }
    void access(Map<String, Object> value) { offer(new Entry(false, value)); }
    private void offer(Entry value) {
        if (!queue.offer(value) && dropped.incrementAndGet() == 1)
            LogManager.getLogger(HistoryRecorder.class).error("历史记录写入队列已满，部分记录未保存，请检查数据库连接与存储空间");
    }
    boolean flush() {
        if (pending.isEmpty()) queue.drainTo(pending, 2048);
        if (pending.isEmpty()) return true;
        try {
            database.writeHistory(pending.stream().filter(Entry::traffic).map(Entry::data).toList(),
                    pending.stream().filter(entry -> !entry.traffic()).map(Entry::data).toList());
            pending.clear(); error = ""; return true;
        } catch (SQLException failure) {
            if (error.isEmpty()) LogManager.getLogger(HistoryRecorder.class).error("历史记录保存失败，将保留待写入批次并重试：{}", failure.getClass().getSimpleName());
            error = "历史记录保存失败，请检查数据库连接、存储空间、权限或占用情况"; return false;
        }
    }
    void finish() { while ((!queue.isEmpty() || !pending.isEmpty()) && flush()) { } }
    Map<String, Object> status() {
        return Map.of("pendingRecords", queue.size() + pending.size(), "droppedRecords", dropped.get(), "error", error);
    }
}
