package com.blacicada.control;

import com.blacicada.io.KernelDatabase;
import java.nio.file.Path;
import java.sql.*;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.junit.jupiter.api.Assertions.*;

class AccessAggregationTest {
    @TempDir Path directory;
    static class MutableClock extends Clock {
        long time = 1000;
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(instant(), zone); }
        @Override public Instant instant() { return Instant.ofEpochMilli(time); }
    }
    static Map<String, Object> event(String target, String state, long time) {
        return Map.of("target", target, "state", state, "createdAt", time, "completedAt", time + 10);
    }
    @SuppressWarnings("unchecked")
    static List<Map<String, Object>> rows(KernelDatabase db) throws Exception {
        return (List<Map<String, Object>>) db.accessHistory(100, "", false, "recent", false, Long.MAX_VALUE, "").get("items");
    }
    @Test void onlyMinuteBoundaryAndStopPersistDomainAttemptsAndFailureTime() throws Exception {
        var path = directory.resolve("access.db"); var clock = new MutableClock();
        try (var db = new KernelDatabase(path)) {
            var recorder = new HistoryRecorder(db, clock);
            recorder.access(event("EXAMPLE.com.:443", "pending", 100));
            recorder.access(event("example.com:443", "connected", 100));
            recorder.access(event("example.com:80", "pending", 200));
            recorder.access(event("example.com:80", "failed", 200));
            recorder.access(event("sub.example.com:443", "pending", 300));
            recorder.access(event("sub.example.com:443", "cancelled", 300));
            recorder.access(event("[::1]:53", "pending", 400));
            recorder.access(event("[0:0:0:0:0:0:0:1]:443", "pending", 500));
            for (long now : new long[]{1000, 10000, 20000, 59999}) {
                clock.time = now; recorder.tick(); assertTrue(rows(db).isEmpty());
            }
            clock.time = 60000; recorder.tick();
            var all = rows(db); assertEquals(3, all.size());
            var domain = all.stream().filter(r -> r.get("host").equals("example.com")).findFirst().orElseThrow();
            assertEquals(2L, domain.get("connectionCount")); assertEquals(200L, domain.get("lastAccessAt")); assertEquals(210L, domain.get("lastFailureAt"));
            assertEquals(0L, all.stream().filter(r -> r.get("host").equals("sub.example.com")).findFirst().orElseThrow().get("lastFailureAt"));
            recorder.access(event("example.com:8080", "pending", 700));
            recorder.access(event("example.com:8080", "connected", 700));
            recorder.finish(); recorder.finish();
            assertEquals(3L, rows(db).getFirst().get("connectionCount")); assertEquals(210L, rows(db).getFirst().get("lastFailureAt"));
        }
        try (var db = new KernelDatabase(path)) { assertEquals(3L, rows(db).getFirst().get("connectionCount")); }
    }
    @Test void failureArrivingInNextMinuteUpdatesTimestampWithoutAnotherAttempt() throws Exception {
        try (var db = new KernelDatabase(directory.resolve("late.db"))) {
            var clock = new MutableClock(); var recorder = new HistoryRecorder(db, clock);
            recorder.access(event("example.com:443", "pending", 59000)); clock.time = 60000; recorder.tick();
            recorder.access(event("example.com:443", "failed", 61000)); recorder.access(event("example.com:80", "pending", 62000));
            clock.time = 120000; recorder.tick();
            var row = rows(db).getFirst(); assertEquals(2L, row.get("connectionCount")); assertEquals(61010L, row.get("lastFailureAt"));
        }
    }
    @Test void failedBatchesKeepNewArrivalsAndDuplicateCommitIsIdempotent() throws Exception {
        var path = directory.resolve("retry.db");
        try (var db = new KernelDatabase(path); var sql = DriverManager.getConnection("jdbc:sqlite:" + path); var statement = sql.createStatement()) {
            var clock = new MutableClock(); var recorder = new HistoryRecorder(db, clock);
            recorder.access(event("example.com:443", "pending", 100));
            statement.execute("CREATE TRIGGER reject_access BEFORE INSERT ON access_domains BEGIN SELECT RAISE(FAIL,'测试写入失败'); END");
            clock.time = 60000; recorder.tick(); assertTrue(rows(db).isEmpty());
            recorder.access(event("example.com:80", "pending", 200));
            statement.execute("DROP TRIGGER reject_access"); recorder.finish(); assertEquals(2L, rows(db).getFirst().get("connectionCount"));
            var batch = List.<Map<String, Object>>of(Map.of("host", "example.com", "batchId", "不确定提交批次", "connectionCount", 5L, "lastAccessAt", 100L, "lastFailureAt", 150L));
            db.writeHistory(List.of(), batch); db.writeHistory(List.of(), batch);
            assertEquals(7L, rows(db).getFirst().get("connectionCount")); assertEquals(200L, rows(db).getFirst().get("lastAccessAt"));
        }
    }
    @Test void allColumnsSortBothDirectionsAcrossPagesIncludingTiesAndNoFailure() throws Exception {
        try (var db = new KernelDatabase(directory.resolve("sorting.db"))) {
            var values = List.<Map<String, Object>>of(
                    Map.of("host", "b.example", "batchId", "排序", "connectionCount", 20L, "lastAccessAt", 100L, "lastFailureAt", 50L),
                    Map.of("host", "a.example", "batchId", "排序", "connectionCount", 3L, "lastAccessAt", 200L, "lastFailureAt", 0L),
                    Map.of("host", "c.example", "batchId", "排序", "connectionCount", 20L, "lastAccessAt", 100L, "lastFailureAt", 50L),
                    Map.of("host", "d.example", "batchId", "排序", "connectionCount", 0L, "lastAccessAt", 0L, "lastFailureAt", 0L));
            db.writeHistory(List.of(), values);
            for (String order : List.of("host", "count", "recent", "failure")) {
                for (boolean ascending : new boolean[]{true, false}) {
                    String field = switch (order) { case "host" -> "host"; case "count" -> "connectionCount"; case "recent" -> "lastAccessAt"; default -> "lastFailureAt"; };
                    var expected = new ArrayList<>(values);
                    expected.sort((a, b) -> {
                        int comparison = order.equals("host") ? ((String) a.get(field)).compareTo((String) b.get(field)) : Long.compare((long) a.get(field), (long) b.get(field));
                        return comparison == 0 ? ((String) a.get("host")).compareTo((String) b.get("host")) : ascending ? comparison : -comparison;
                    });
                    var actual = new ArrayList<String>(); long cursor = 0; String host = "";
                    for (int pageIndex = 0; pageIndex < 5; pageIndex++) {
                        var page = db.accessHistory(1, "", false, order, ascending, cursor, host);
                        var rows = (List<?>) page.get("items");
                        for (var row : rows) actual.add((String) ((Map<?, ?>) row).get("host"));
                        if (!(boolean) page.get("hasMore")) break;
                        cursor = (long) page.get("nextValue"); host = (String) page.get("nextHost");
                    }
                    assertEquals(expected.stream().map(row -> row.get("host")).toList(), actual, order + " " + ascending);
                }
            }
        }
    }
    @Test void filtersAndCompoundCursorHandleTiesWithoutDuplicatesAndOldRowsStayUntouched() throws Exception {
        var path = directory.resolve("paging.db");
        try (var db = new KernelDatabase(path); var sql = DriverManager.getConnection("jdbc:sqlite:" + path); var statement = sql.createStatement()) {
            statement.execute("CREATE TABLE access_records(marker TEXT)"); statement.execute("INSERT INTO access_records VALUES('旧访问记录')");
            var batch = new ArrayList<Map<String, Object>>();
            for (int i = 0; i < 4; i++) batch.add(Map.of("host", i + ".example.test", "batchId", "分页", "connectionCount", (long) i + 1,
                    "lastAccessAt", 100L, "lastFailureAt", i == 0 ? 0L : 90L));
            db.writeHistory(List.of(), batch);
            var page = db.accessHistory(2, "EXAMPLE", true, "recent", false, Long.MAX_VALUE, "");
            assertEquals(true, page.get("hasMore")); assertEquals("2.example.test", page.get("nextHost"));
            var next = db.accessHistory(2, "example", true, "recent", false, (long) page.get("nextValue"), (String) page.get("nextHost"));
            assertEquals(false, next.get("hasMore")); assertEquals(1, ((List<?>) next.get("items")).size());
            assertEquals("3.example.test", ((Map<?, ?>) ((List<?>) db.accessHistory(1, "", false, "count", false, Long.MAX_VALUE, "").get("items")).getFirst()).get("host"));
            assertTrue(((List<?>) db.accessHistory(2, "%", false, "recent", false, Long.MAX_VALUE, "").get("items")).isEmpty());
            db.maintainTraffic(Instant.parse("2099-01-01T00:00:00Z").toEpochMilli(), ZoneOffset.UTC, true);
            assertEquals(4, rows(db).size());
        }
        try (var db = new KernelDatabase(path); var sql = DriverManager.getConnection("jdbc:sqlite:" + path); var statement = sql.createStatement(); var row = statement.executeQuery("SELECT marker FROM access_records")) {
            assertEquals(4, rows(db).size()); assertTrue(row.next()); assertEquals("旧访问记录", row.getString(1));
        }
    }
}
