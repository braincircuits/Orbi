package com.blacicada.control;

import java.time.Instant;
import java.util.*;

/** 有界事件历史；慢订阅者通过快照恢复，不挤占代理传输内存。 */
public final class ControlEvents implements AutoCloseable {
    public record Event(long id, String type, String time, Object data) { }
    public record Batch(boolean reset, long cursor, List<Event> events) { }
    private final ArrayDeque<Event> history = new ArrayDeque<>();
    private long sequence;
    private boolean closed;
    public synchronized void emit(String type, Object data) {
        if (closed) return;
        history.add(new Event(++sequence, type, Instant.now().toString(), data));
        while (history.size() > 512) history.removeFirst();
        notifyAll();
    }
    public synchronized long cursor() { return sequence; }
    public synchronized Batch await(long after, long millis) throws InterruptedException {
        if (!closed && after == sequence && millis > 0) wait(millis);
        boolean reset = after > sequence || (!history.isEmpty() && after < history.getFirst().id() - 1);
        return new Batch(reset, sequence, reset ? List.of() : history.stream().filter(e -> e.id() > after).toList());
    }
    @Override public synchronized void close() { closed = true; notifyAll(); }
}
