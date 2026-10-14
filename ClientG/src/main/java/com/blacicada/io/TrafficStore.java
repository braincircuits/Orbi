package com.blacicada.io;

import com.google.gson.*;
import java.sql.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** 分钟明细与小时汇总共用配置库连接，由控制线程串行调用。 */
final class TrafficStore {
    private final Connection connection;
    private final StorageConfig.Type type;
    private static final Gson JSON = new Gson();
    TrafficStore(Connection connection, StorageConfig.Type type) throws SQLException {
        this.connection = connection; this.type = type;
        create("traffic_minutes", """
                minute_start BIGINT PRIMARY KEY, hour_start BIGINT NOT NULL, hour_end BIGINT NOT NULL,
                sent_bytes BIGINT NOT NULL, received_bytes BIGINT NOT NULL, active_duration_ms BIGINT NOT NULL,
                session_totals TEXT NOT NULL, rolled_sent_bytes BIGINT NOT NULL,
                rolled_received_bytes BIGINT NOT NULL, rolled_duration_ms BIGINT NOT NULL,
                CHECK(minute_start>=0 AND minute_start%60000=0), CHECK(sent_bytes>=0), CHECK(received_bytes>=0)
                """, "按自然分钟合并业务流量，仅保留最近24小时；会话快照用于写入重试去重");
        create("traffic_hours", """
                hour_start BIGINT PRIMARY KEY, hour_end BIGINT NOT NULL, sent_bytes BIGINT NOT NULL,
                received_bytes BIGINT NOT NULL, active_duration_ms BIGINT NOT NULL
                """, "按自然小时保存业务流量，保留最近12个自然月");
        // 不转换旧结构、不清除旧数据，由使用者手动处理历史表。
        try (var query = connection.prepareStatement("SELECT session_totals,rolled_sent_bytes FROM traffic_minutes WHERE 1=0")) {
            query.executeQuery().close();
        } catch (SQLException failure) {
            throw new SQLException("流量表结构与当前版本不符，请手动处理流量历史表后重新启动", failure);
        }
    }
    private void create(String name, String columns, String description) throws SQLException {
        try (var rows = connection.getMetaData().getTables(type == StorageConfig.Type.MYSQL ? connection.getCatalog() : null,
                type == StorageConfig.Type.POSTGRESQL ? "public" : null, name, new String[]{"TABLE"})) {
            if (rows.next()) return;
        }
        var notes = Map.ofEntries(
                Map.entry("minute_start", "自然分钟起点，Unix毫秒"), Map.entry("hour_start", "内核时区自然小时起点，Unix毫秒"),
                Map.entry("hour_end", "小时结束边界，Unix毫秒"), Map.entry("sent_bytes", "区间发送业务字节数"),
                Map.entry("received_bytes", "区间接收业务字节数"), Map.entry("active_duration_ms", "实际采集时长，毫秒"),
                Map.entry("session_totals", "各启动会话已保存的分钟快照，用于幂等合并"),
                Map.entry("rolled_sent_bytes", "已汇总到小时表的发送字节数"), Map.entry("rolled_received_bytes", "已汇总到小时表的接收字节数"),
                Map.entry("rolled_duration_ms", "已汇总到小时表的采集时长"));
        for (var note : notes.entrySet()) {
            columns = columns.replaceAll("(" + note.getKey() + " (?:BIGINT|TEXT) (?:PRIMARY KEY|NOT NULL))",
                    "$1" + (type == StorageConfig.Type.MYSQL ? " COMMENT '" + note.getValue() + "'" : " /* " + note.getValue() + " */"));
        }
        String suffix = type == StorageConfig.Type.MYSQL
                ? " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='" + description + "'" : "";
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE TABLE " + name + " (/* " + description + " */ " + columns + ")" + suffix);
            if (type == StorageConfig.Type.POSTGRESQL) {
                statement.execute("COMMENT ON TABLE " + name + " IS '" + description + "'");
                for (var note : notes.entrySet()) if (columns.contains(note.getKey() + " "))
                    statement.execute("COMMENT ON COLUMN " + name + "." + note.getKey() + " IS '" + note.getValue() + "'");
            }
        }
    }
    static ZonedDateTime hour(long time, ZoneId zone) {
        return Instant.ofEpochMilli(time).atZone(zone).truncatedTo(ChronoUnit.HOURS);
    }
    private static long number(Map<String, Object> value, String key) { return ((Number) value.get(key)).longValue(); }
    private String upsert(String key, String columns) {
        var updates = Arrays.stream(columns.split(",")).map(column -> column + "="
                + (type == StorageConfig.Type.MYSQL ? "incoming." : "excluded.") + column).toList();
        return type == StorageConfig.Type.MYSQL ? " AS incoming ON DUPLICATE KEY UPDATE " + String.join(",", updates)
                : " ON CONFLICT(" + key + ") DO UPDATE SET " + String.join(",", updates);
    }
    /** 每个会话提交该分钟的最终值；持久化快照使失败重试和同分钟重启均不重复计数。 */
    void write(Map<String, Object> item, ZoneId zone) throws SQLException {
        long time = number(item, "minuteStart"), sent = number(item, "sentBytes"), received = number(item, "receivedBytes");
        long duration = number(item, "activeDurationMillis");
        if (time < 0 || time % 60000 != 0 || sent < 0 || received < 0 || duration < 0 || duration > 60000)
            throw new SQLException("分钟流量记录无效");
        JsonObject sessions = new JsonObject();
        long totalSent = 0, totalReceived = 0, totalDuration = 0;
        var start = hour(time, zone);
        long hourStart = start.toInstant().toEpochMilli(), hourEnd = start.plusHours(1).toInstant().toEpochMilli();
        try (var query = connection.prepareStatement("SELECT * FROM traffic_minutes WHERE minute_start=?")) {
            query.setLong(1, time);
            try (var row = query.executeQuery()) {
                if (row.next()) {
                    sessions = JsonParser.parseString(row.getString("session_totals")).getAsJsonObject();
                    totalSent = row.getLong("sent_bytes"); totalReceived = row.getLong("received_bytes");
                    totalDuration = row.getLong("active_duration_ms");
                    hourStart = row.getLong("hour_start"); hourEnd = row.getLong("hour_end");
                }
            }
        }
        String session = (String) item.get("sessionId");
        var previous = sessions.getAsJsonArray(session);
        long oldSent = previous == null ? 0 : previous.get(0).getAsLong();
        long oldReceived = previous == null ? 0 : previous.get(1).getAsLong();
        long oldDuration = previous == null ? 0 : previous.get(2).getAsLong();
        sent = Math.max(sent, oldSent); received = Math.max(received, oldReceived); duration = Math.max(duration, oldDuration);
        var next = new JsonArray(); next.add(sent); next.add(received); next.add(duration); sessions.add(session, next);
        try (var insert = connection.prepareStatement("INSERT INTO traffic_minutes(minute_start,hour_start,hour_end,sent_bytes,received_bytes,active_duration_ms,session_totals,rolled_sent_bytes,rolled_received_bytes,rolled_duration_ms) VALUES(?,?,?,?,?,?,?,0,0,0)"
                + upsert("minute_start", "sent_bytes,received_bytes,active_duration_ms,session_totals"))) {
            insert.setLong(1, time); insert.setLong(2, hourStart); insert.setLong(3, hourEnd);
            insert.setLong(4, totalSent + sent - oldSent); insert.setLong(5, totalReceived + received - oldReceived);
            insert.setLong(6, totalDuration + duration - oldDuration); insert.setString(7, JSON.toJson(sessions)); insert.executeUpdate();
        }
    }
    /** 汇总与检查点在同一事务提交；只累计尚未进入小时表的部分，允许补写及重试。 */
    void settle(long now) throws SQLException {
        String sql = "SELECT hour_start,hour_end,SUM(sent_bytes-rolled_sent_bytes),SUM(received_bytes-rolled_received_bytes),SUM(active_duration_ms-rolled_duration_ms) FROM traffic_minutes WHERE hour_end<=? AND (sent_bytes<>rolled_sent_bytes OR received_bytes<>rolled_received_bytes OR active_duration_ms<>rolled_duration_ms) GROUP BY hour_start,hour_end";
        var pending = new ArrayList<long[]>();
        try (var query = connection.prepareStatement(sql)) {
            query.setLong(1, now);
            try (var rows = query.executeQuery()) { while (rows.next()) pending.add(new long[]{rows.getLong(1), rows.getLong(2), rows.getLong(3), rows.getLong(4), rows.getLong(5)}); }
        }
        for (var value : pending) {
            try (var query = connection.prepareStatement("SELECT sent_bytes,received_bytes,active_duration_ms FROM traffic_hours WHERE hour_start=?")) {
                query.setLong(1, value[0]);
                try (var row = query.executeQuery()) { if (row.next()) for (int i = 0; i < 3; i++) value[i + 2] += row.getLong(i + 1); }
            }
            try (var insert = connection.prepareStatement("INSERT INTO traffic_hours(hour_start,hour_end,sent_bytes,received_bytes,active_duration_ms) VALUES(?,?,?,?,?)"
                    + upsert("hour_start", "hour_end,sent_bytes,received_bytes,active_duration_ms"))) {
                for (int i = 0; i < value.length; i++) insert.setLong(i + 1, value[i]); insert.executeUpdate();
            }
        }
        try (var update = connection.prepareStatement("UPDATE traffic_minutes SET rolled_sent_bytes=sent_bytes,rolled_received_bytes=received_bytes,rolled_duration_ms=active_duration_ms WHERE hour_end<=? AND (sent_bytes<>rolled_sent_bytes OR received_bytes<>rolled_received_bytes OR active_duration_ms<>rolled_duration_ms)")) {
            update.setLong(1, now); update.executeUpdate();
        }
    }
    void clean(long now, ZoneId zone, boolean hours) throws SQLException {
        try (var delete = connection.prepareStatement("DELETE FROM traffic_minutes WHERE minute_start<? AND sent_bytes=rolled_sent_bytes AND received_bytes=rolled_received_bytes AND active_duration_ms=rolled_duration_ms")) {
            delete.setLong(1, Math.floorDiv(now, 60000) * 60000 - 86400000L); delete.executeUpdate();
        }
        if (hours) try (var delete = connection.prepareStatement("DELETE FROM traffic_hours WHERE hour_end<=?")) {
            delete.setLong(1, Instant.ofEpochMilli(now).atZone(zone).minusMonths(12).toInstant().toEpochMilli()); delete.executeUpdate();
        }
    }
    Map<String, Object> series(long now, ZoneId zone, boolean hourly) throws SQLException {
        var endHour = hour(now, zone);
        long end = hourly ? endHour.toInstant().toEpochMilli() : Math.floorDiv(now, 60000) * 60000 + 60000;
        long start = hourly ? endHour.minusMonths(1).toInstant().toEpochMilli() : end - 86400000L;
        String column = hourly ? "hour_start" : "minute_start", table = hourly ? "traffic_hours" : "traffic_minutes";
        var stored = new HashMap<Long, long[]>();
        try (var query = connection.prepareStatement("SELECT " + column + ",sent_bytes,received_bytes FROM " + table + " WHERE " + column + ">=? AND " + column + "<? ORDER BY " + column)) {
            query.setLong(1, start); query.setLong(2, end);
            try (var row = query.executeQuery()) { while (row.next()) stored.put(row.getLong(1), new long[]{row.getLong(2), row.getLong(3)}); }
        }
        var buckets = new ArrayList<Map<String, Object>>();
        long sent = 0, received = 0, count = 0;
        for (long time = start; time < end;) {
            long next = Math.min(end, time + (hourly ? 3600000L : 60000L));
            var value = stored.get(time);
            long up = value == null ? 0 : value[0], down = value == null ? 0 : value[1];
            if (value != null) count++;
            sent += up; received += down;
            var local = Instant.ofEpochMilli(time).atZone(zone);
            buckets.add(Map.of("from", time, "to", next, "sentBytes", up, "receivedBytes", down,
                    "recordCount", value == null ? 0L : 1L,
                    "label", local.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm xxx")) + (next > now ? " · 未结束" : ""),
                    "shortLabel", local.format(DateTimeFormatter.ofPattern(hourly ? "MM-dd HH:mm" : "HH:mm"))));
            time = next;
        }
        return Map.of("from", start, "to", end, "zoneId", zone.getId(), "interval", hourly ? "hour" : "minute",
                "buckets", buckets, "sentBytes", sent, "receivedBytes", received, "recordCount", count);
    }
}
