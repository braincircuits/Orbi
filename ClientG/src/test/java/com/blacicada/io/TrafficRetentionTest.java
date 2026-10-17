package com.blacicada.io;

import java.nio.file.*;
import java.sql.*;
import java.time.*;
import java.util.*;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class TrafficRetentionTest {
    @TempDir
    Path directory;

    static long at(String value) {
        return Instant.parse(value).toEpochMilli();
    }

    static Map<String, Object> minute(String session, long time, long sent) {
        return Map.of("sessionId", session, "minuteStart", time, "activeDurationMillis", 10000L, "sentBytes", sent, "receivedBytes", sent * 2);
    }

    long number(Connection connection, String sql) throws SQLException {
        try (var query = connection.createStatement(); var row = query.executeQuery(sql)) {
            assertTrue(row.next());
            return row.getLong(1);
        }
    }

    @Test
    void restartsRetriesLateWritesAndCleanupPreserveExactHourTotals() throws Exception {
        var file = directory.resolve("traffic.db");
        long start = at("2026-10-14T10:00:00Z"), end = start + 3600000;
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file)) {
            var first = minute("甲", start, 100);
            db.writeHistory(List.of(first, minute("乙", start, 50)), List.of());
            db.writeHistory(List.of(first), List.of());
            assertEquals(1, number(sql, "SELECT COUNT(*) FROM traffic_minutes"));
            assertEquals(150, number(sql, "SELECT SUM(sent_bytes) FROM traffic_minutes"));
            db.maintainTraffic(end - 1, ZoneOffset.UTC, true);
            assertEquals(0, number(sql, "SELECT COUNT(*) FROM traffic_hours"));
            db.maintainTraffic(end, ZoneOffset.UTC, false);
            db.maintainTraffic(end, ZoneOffset.UTC, false);
            assertEquals(150, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
            db.writeHistory(List.of(minute("甲", start, 120)), List.of());
            db.maintainTraffic(end + 60000, ZoneOffset.UTC, false);
            assertEquals(170, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
        }
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file)) {
            db.maintainTraffic(start + 86400000 + 60000, ZoneOffset.UTC, false);
            assertEquals(0, number(sql, "SELECT COUNT(*) FROM traffic_minutes"));
            assertEquals(170, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
            assertEquals(170L, db.trafficSeries(start + 86400000 + 60000, ZoneOffset.UTC, true).get("sentBytes"));
        }
    }

    @Test
    void failedRollupNeverDeletesMinutesAndRetryDoesNotDuplicateHours() throws Exception {
        var file = directory.resolve("retry.db");
        long start = at("2026-10-14T10:00:00Z");
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file); var statement = sql.createStatement()) {
            db.writeHistory(List.of(minute("甲", start, 100)), List.of());
            statement.execute("CREATE TRIGGER fail_rollup BEFORE INSERT ON traffic_hours BEGIN SELECT RAISE(FAIL, '测试汇总失败'); END");
            assertThrows(SQLException.class, () -> db.maintainTraffic(start + 90000000, ZoneOffset.UTC, false));
            assertEquals(1, number(sql, "SELECT COUNT(*) FROM traffic_minutes"));
            assertEquals(0, number(sql, "SELECT SUM(rolled_sent_bytes) FROM traffic_minutes"));
            statement.execute("DROP TRIGGER fail_rollup");
            db.maintainTraffic(start + 90000000, ZoneOffset.UTC, false);
            db.maintainTraffic(start + 90000000, ZoneOffset.UTC, false);
            assertEquals(0, number(sql, "SELECT COUNT(*) FROM traffic_minutes"));
            assertEquals(100, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
        }
    }

    @Test
    void calendarMonthRetentionAndHourlyWindowUseKernelZone() throws Exception {
        var file = directory.resolve("calendar.db");
        var zone = ZoneId.of("America/New_York");
        long now = at("2025-02-28T08:00:00Z");
        long cutoff = Instant.ofEpochMilli(now).atZone(zone).minusMonths(12).toInstant().toEpochMilli();
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file); var insert = sql.prepareStatement("INSERT INTO traffic_hours VALUES(?,?,10,20,60000)")) {
            for (long end : new long[]{cutoff, cutoff + 3600000}) {
                insert.setLong(1, end - 3600000);
                insert.setLong(2, end);
                insert.executeUpdate();
            }
            db.maintainTraffic(now, zone, false);
            assertEquals(2, number(sql, "SELECT COUNT(*) FROM traffic_hours"));
            db.maintainTraffic(now, zone, true);
            assertEquals(1, number(sql, "SELECT COUNT(*) FROM traffic_hours"));
            var summary = db.trafficSeries(at("2026-11-15T08:00:00Z"), zone, true);
            assertEquals(zone.getId(), summary.get("zoneId"));
            assertEquals(31 * 24 + 1, ((List<?>) summary.get("buckets")).size());
            assertTrue(summary.toString().contains("2026-11-01 01:00 -04:00"));
            assertTrue(summary.toString().contains("2026-11-01 01:00 -05:00"));
        }
    }

    @Test
    void halfHourBackwardTransitionPreservesCompletedHourBoundariesAndTotals() throws Exception {
        var zone = ZoneId.of("Australia/Lord_Howe");
        var file = directory.resolve("half-hour-backward.db");
        long start = at("2026-04-04T14:00:00Z"), end = at("2026-04-04T15:30:00Z");
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file)) {
            var store = new TrafficStore(sql, StorageConfig.Type.SQLITE);
            store.write(minute("甲", at("2026-04-04T14:45:00Z"), 10), zone);
            store.write(minute("甲", at("2026-04-04T15:15:00Z"), 20), zone);
            store.write(minute("甲", at("2026-04-04T16:05:00Z"), 40), zone);
            assertEquals(end, number(sql, "SELECT hour_end FROM traffic_minutes WHERE minute_start=" + at("2026-04-04T15:15:00Z")));
            db.maintainTraffic(end - 1, zone, false);
            assertEquals(0, number(sql, "SELECT COUNT(*) FROM traffic_hours"), "回拨后的同一自然小时尚未结束，不能提前汇总");
            db.maintainTraffic(end, zone, false);
            assertEquals(30, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
            db.maintainTraffic(at("2026-04-04T17:00:00Z"), zone, false);
            var summary = db.trafficSeries(at("2026-04-04T17:00:00Z"), zone, true);
            assertEquals(70L, summary.get("sentBytes"));
            assertEquals(140L, summary.get("receivedBytes"));
            assertHour(summary, start, end, 30);
            assertHour(summary, end, at("2026-04-04T16:30:00Z"), 40);
        }
    }

    @Test
    void halfHourForwardTransitionPreservesCompletedHourBoundariesAndTotals() throws Exception {
        var zone = ZoneId.of("Australia/Lord_Howe");
        var file = directory.resolve("half-hour-forward.db");
        long start = at("2026-10-03T15:30:00Z"), end = at("2026-10-03T16:00:00Z");
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file)) {
            var store = new TrafficStore(sql, StorageConfig.Type.SQLITE);
            store.write(minute("甲", at("2026-10-03T14:45:00Z"), 10), zone);
            store.write(minute("甲", at("2026-10-03T15:45:00Z"), 20), zone);
            store.write(minute("甲", at("2026-10-03T16:15:00Z"), 40), zone);
            assertEquals(end, number(sql, "SELECT hour_end FROM traffic_minutes WHERE minute_start=" + at("2026-10-03T15:45:00Z")));
            db.maintainTraffic(end - 1, zone, false);
            assertEquals(10, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"), "跳时后的半小时桶尚未结束");
            db.maintainTraffic(end, zone, false);
            assertEquals(30, number(sql, "SELECT SUM(sent_bytes) FROM traffic_hours"));
            long now = at("2026-10-03T18:00:00Z");
            db.maintainTraffic(now, zone, false);
            var summary = db.trafficSeries(now, zone, true);
            assertEquals(70L, summary.get("sentBytes"));
            assertEquals(140L, summary.get("receivedBytes"));
            assertHour(summary, at("2026-10-03T14:30:00Z"), start, 10);
            assertHour(summary, start, end, 20);
            assertHour(summary, end, at("2026-10-03T17:00:00Z"), 40);
        }
    }

    @Test
    void hourlyWindowStartsAtANaturalHourDuringHalfHourForwardTransition() throws Exception {
        var zone = ZoneId.of("Australia/Lord_Howe");
        var file = directory.resolve("half-hour-window.db");
        long start = at("2026-09-03T15:30:00Z"), end = at("2026-09-03T16:30:00Z");
        long now = at("2026-10-03T15:45:00Z");
        try (var db = new KernelDatabase(file); var sql = DriverManager.getConnection("jdbc:sqlite:" + file)) {
            var store = new TrafficStore(sql, StorageConfig.Type.SQLITE);
            store.write(minute("甲", start, 123), zone);
            db.maintainTraffic(end, zone, false);
            var summary = db.trafficSeries(now, zone, true);
            assertEquals(start, summary.get("from"));
            assertEquals(123L, summary.get("sentBytes"));
            assertHour(summary, start, end, 123);
        }
    }

    private static void assertHour(Map<String, Object> summary, long start, long end, long sent) {
        var buckets = (List<?>) summary.get("buckets");
        var bucket = buckets.stream().map(value -> (Map<?, ?>) value)
                .filter(value -> Long.valueOf(start).equals(value.get("from"))).findFirst().orElseThrow();
        assertEquals(end, bucket.get("to"));
        assertEquals(sent, bucket.get("sentBytes"));
        assertEquals(sent * 2, bucket.get("receivedBytes"));
    }

    @Test
    void oldMinuteTableIsRejectedWithoutRewritingUserData() throws Exception {
        var file = directory.resolve("old.db");
        try (var db = new KernelDatabase(file)) {
        }
        try (var sql = DriverManager.getConnection("jdbc:sqlite:" + file); var statement = sql.createStatement()) {
            statement.execute("DROP TABLE traffic_minutes");
            statement.execute("CREATE TABLE traffic_minutes(original TEXT)");
            statement.execute("INSERT INTO traffic_minutes VALUES('用户自行处理')");
        }
        var failure = assertThrows(java.io.IOException.class, () -> new KernelDatabase(file));
        assertTrue(failure.getMessage().contains("手动处理"));
        try (var sql = DriverManager.getConnection("jdbc:sqlite:" + file); var query = sql.createStatement(); var row = query.executeQuery("SELECT original FROM traffic_minutes")) {
            assertTrue(row.next());
            assertEquals("用户自行处理", row.getString(1));
        }
    }
}
