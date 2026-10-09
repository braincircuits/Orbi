package com.blacicada.control;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.core.*;
import org.apache.logging.log4j.core.appender.AbstractAppender;
import org.apache.logging.log4j.core.config.Property;
import java.time.Instant;
import java.util.*;
import java.util.function.UnaryOperator;

/** 保留有限数量的脱敏日志，代理客户端按序号增量读取。 */
public final class ControlLogs extends AbstractAppender implements AutoCloseable {
    private final ArrayDeque<Map<String, Object>> entries = new ArrayDeque<>();
    private final ControlEvents events;
    private final UnaryOperator<String> redact;
    private final LoggerContext context;
    private long sequence;
    public ControlLogs(ControlEvents events, UnaryOperator<String> redact) {
        super("kernel-control-" + UUID.randomUUID(), null, null, true, Property.EMPTY_ARRAY);
        this.events = events; this.redact = redact; start();
        // 显式使用内核类加载器，确保精简运行时中采集器与业务日志属于同一上下文。
        context = (LoggerContext) LogManager.getContext(ControlLogs.class.getClassLoader(), false);
        context.getRootLogger().addAppender(this);
    }
    @Override public synchronized void append(LogEvent event) {
        String text = redact.apply(event.getMessage().getFormattedMessage());
        if (text.length() > 4096) text = text.substring(0, 4096) + "…";
        Map<String, Object> entry = Map.of("id", ++sequence, "time", Instant.ofEpochMilli(event.getTimeMillis()).toString(),
                "level", event.getLevel().name(), "logger", event.getLoggerName(), "message", text);
        entries.add(entry); while (entries.size() > 500) entries.removeFirst();
        events.emit("log", entry);
    }
    public static Set<String> parseLevels(String value) {
        if (value == null) return Set.of();
        Set<String> levels = new LinkedHashSet<>();
        for (String item : value.split(",", -1)) {
            String level = item.trim().toUpperCase(Locale.ROOT);
            if (!Set.of("FATAL", "ERROR", "WARN", "INFO", "DEBUG", "TRACE").contains(level))
                throw new ControlException(400, "INVALID_LOG_LEVEL", "日志级别必须为 FATAL、ERROR、WARN、INFO、DEBUG 或 TRACE", "levels");
            levels.add(level);
        }
        return Set.copyOf(levels);
    }
    public synchronized Map<String, Object> read(long after, int limit, Set<String> levels) {
        var items = entries.stream().filter(e -> (long) e.get("id") > after)
                .filter(e -> levels.isEmpty() || levels.contains(e.get("level"))).limit(limit).toList();
        long cursor = items.isEmpty() ? sequence : (long) items.getLast().get("id");
        return Map.of("cursor", cursor, "latestCursor", sequence, "truncated", !entries.isEmpty() && after < (long) entries.getFirst().get("id") - 1,
                "items", items);
    }
    @Override public void close() {
        context.getRootLogger().removeAppender(this);
        stop();
    }
}
