package com.blacicada.io;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import java.io.IOException;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/** 远程测试必须指向独立空库，测试写入的配置与历史保留，绝不清理用户已有数据库。 */
class DatabaseBackendsTest {
    @TempDir Path directory;
    @Test void sqliteContract() throws Exception { verify(StorageConfig.sqlite(directory.resolve("kernel.db"))); }
    @Test void postgresqlContract() throws Exception { verify(remote("NETWORK_TEST_POSTGRESQL_CONFIG", StorageConfig.Type.POSTGRESQL)); }
    @Test void mysqlContract() throws Exception { verify(remote("NETWORK_TEST_MYSQL_CONFIG", StorageConfig.Type.MYSQL)); }

    private StorageConfig remote(String variable, StorageConfig.Type type) throws Exception {
        String path = System.getenv(variable);
        assumeTrue(path != null && !path.isBlank(), "未提供独立测试数据库配置：" + variable);
        StorageConfig config = StorageConfig.load(Path.of(path));
        assertEquals(type, config.type());
        // 在内核初始化前确认完全空库；防止误用生产库或覆盖上次测试结果。
        try (var connection = config.connect(); var tables = connection.getMetaData().getTables(
                type == StorageConfig.Type.MYSQL ? connection.getCatalog() : null,
                type == StorageConfig.Type.POSTGRESQL ? "public" : null, "%", new String[]{"TABLE", "VIEW"})) {
            assertFalse(tables.next(), "数据库不是空库，测试已中止");
        }
        return config;
    }
    private KernelConfig configuration() {
        Properties local = new Properties(), profile = new Properties();
        local.setProperty("routingMode", "direct"); local.setProperty("routesInline", "# 中文规则\nexample.com\n");
        local.setProperty("routesOverrides", "proxy www.example.com\ndirect ::1");
        profile.setProperty("protocol", "http2"); profile.setProperty("server.host", "localhost"); profile.setProperty("password", "测试口令🔑");
        return new KernelConfig(new ProxyConfig(local, directory), List.of(
                new KernelConfig.Profile("a", "测试连接🔑", new ProxyConfig(profile, directory))), "a");
    }
    private void verify(StorageConfig config) throws Exception {
        long time = 1_800_000_000_000L;
        try (var db = new KernelDatabase(config)) {
            assertEquals(0, db.read().revision());
            assertThrows(IOException.class, () -> new KernelDatabase(config));
            db.stage(configuration(), 0); db.commit();
            db.stage(configuration(), 1); db.rollback();
            assertEquals(1, db.read().revision());
            assertEquals("测试口令🔑", db.read().configuration().profile("a").config().required("password"));
            assertEquals(configuration().local().get("routesInline", ""), db.read().configuration().local().get("routesInline", ""));
            assertThrows(SQLException.class, () -> db.stage(configuration(), 0)); db.rollback();
            // 重复写入不能增加样本；分钟增量超过 32 位，查询时间使用毫秒。
            var samples = List.of(sample("甲", time - 60_000, 5_000_000_000L), sample("甲", time, 5_000_000_010L),
                    sample("甲", time + 60_000, 30L), sample("乙", time, 7L));
            db.writeHistory(samples, List.of(access("a", time, "pending"), access("b", time + 1, "failed"), access("c", time + 2, "failed")));
            db.writeHistory(samples, List.of(access("a", time, "connected")));
            var summary = db.trafficSeries(time + 180_000, java.time.ZoneOffset.UTC, false);
            assertEquals(10_000_000_047L, summary.get("sentBytes")); assertEquals(3L, summary.get("recordCount"));
            db.maintainTraffic(time + 3_600_000, java.time.ZoneOffset.UTC, true);
            assertEquals(10_000_000_047L, db.trafficSeries(time + 3_600_000, java.time.ZoneOffset.UTC, true).get("sentBytes"));
            var page = db.accessHistory(0, Long.MAX_VALUE, Long.MAX_VALUE, 1, "EXAMPLE_%", "failed");
            assertEquals(true, page.get("hasMore"));
            var next = db.accessHistory(0, Long.MAX_VALUE, (long) page.get("nextBeforeId"), 1, "example_%", "failed");
            assertEquals(false, next.get("hasMore"));
            assertEquals(1, ((List<?>) next.get("items")).size());
            assertEquals(1, ((List<?>) db.accessHistory(0, Long.MAX_VALUE, Long.MAX_VALUE, 10, "", "connected").get("items")).size());
            assertEquals(3, ((List<?>) db.accessHistory(0, Long.MAX_VALUE, Long.MAX_VALUE, 10, "", "").get("items")).size());
            // 批处理中任一记录失败时，整批必须回滚。
            var invalid = new HashMap<>(access("invalid", time, "failed")); invalid.put("target", null);
            assertThrows(SQLException.class, () -> db.writeHistory(List.of(sample("失败批次", time, 999)), List.of(invalid)));
            assertEquals(10_000_000_047L, db.trafficSeries(time + 180_000, java.time.ZoneOffset.UTC, false).get("sentBytes"));
            db.stage(configuration(), 1);
        }
        try (var db = new KernelDatabase(config)) {
            assertEquals(1, db.read().revision());
            assertEquals("测试连接🔑", db.read().configuration().profile("a").name());
            db.stage(new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(), ""), 1); db.commit();
            assertTrue(db.read().configuration().connections().isEmpty());
            assertEquals(3, ((List<?>) db.accessHistory(0, Long.MAX_VALUE, Long.MAX_VALUE, 10, "", "").get("items")).size());
        }
        if (config.type() != StorageConfig.Type.SQLITE) {
            try (var connection = config.connect(); var query = connection.createStatement()) {
                String columns = config.type() == StorageConfig.Type.POSTGRESQL
                        ? "SELECT COUNT(*) FROM pg_attribute WHERE attrelid='traffic_minutes'::regclass AND attnum>0 AND NOT attisdropped AND col_description(attrelid,attnum) IS NOT NULL"
                        : "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='traffic_minutes' AND column_comment<>''";
                try (var rows = query.executeQuery(columns)) { assertTrue(rows.next()); assertEquals(10, rows.getInt(1)); }
                String table = config.type() == StorageConfig.Type.POSTGRESQL
                        ? "SELECT obj_description('traffic_minutes'::regclass)"
                        : "SELECT table_comment FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='traffic_minutes'";
                try (var rows = query.executeQuery(table)) { assertTrue(rows.next()); assertTrue(rows.getString(1).contains("自然分钟")); }
            }
            try (var connection = config.connect(); var query = connection.createStatement()) { query.executeUpdate("UPDATE storage_format SET version=99"); }
            assertThrows(IOException.class, () -> new KernelDatabase(config));
            try (var connection = config.connect(); var query = connection.createStatement(); var row = query.executeQuery("SELECT version FROM storage_format")) {
                assertTrue(row.next()); assertEquals(99, row.getInt(1));
            }
        }
    }
    private Map<String, Object> sample(String session, long time, long sent) {
        return Map.of("sessionId", session, "minuteStart", time, "activeDurationMillis", 60_000L, "sentBytes", sent,
                "receivedBytes", 0L);
    }
    private Map<String, Object> access(String id, long time, String state) {
        Map<String, Object> row = new HashMap<>();
        row.put("requestId", id); row.put("sessionId", "测试会话"); row.put("createdAt", time); row.put("completedAt", time + 10);
        row.put("target", "example_%中文.test:443"); row.put("source", "127.0.0.1:1234"); row.put("method", "CONNECT-UDP");
        row.put("route", "proxy"); row.put("protocol", "HTTP/2"); row.put("profileId", "a"); row.put("profileName", "测试连接🔑"); row.put("state", state);
        return row;
    }
}
