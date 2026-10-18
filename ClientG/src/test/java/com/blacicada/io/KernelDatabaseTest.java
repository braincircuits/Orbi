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

class KernelDatabaseTest {
    @TempDir
    Path directory;

    KernelConfig configuration() {
        Properties local = new Properties(), profile = new Properties();
        local.setProperty("bind", "127.0.0.1");
        local.setProperty("port", "12345");
        local.setProperty("routingMode", "direct");
        local.setProperty("routesInline", " # 保留原文\r\nexample.com\r\n\r\n");
        local.setProperty("routesOverrides", "proxy www.example.com\ndirect ::1");
        profile.setProperty("protocol", "http2");
        profile.setProperty("server.host", "localhost");
        profile.setProperty("password", "数据库测试凭据");
        profile.setProperty("maxStreams", "321");
        return new KernelConfig(new ProxyConfig(local, directory), List.of(
                new KernelConfig.Profile("a", "测试连接", new ProxyConfig(profile, directory))), "a");
    }

    @Test
    void restartRestoresConfigurationVersionAndCredentials() throws Exception {
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) {
            assertEquals(0, database.read().revision());
            assertTrue(database.read().configuration().connections().isEmpty());
            database.stage(configuration(), 0);
            database.commit();
        }
        try (var database = new KernelDatabase(file)) {
            var stored = database.read();
            assertEquals(1, stored.revision());
            assertEquals("direct", stored.configuration().routingMode());
            assertEquals("a", stored.configuration().defaultConnectionId());
            assertEquals("数据库测试凭据", stored.configuration().profile("a").config().required("password"));
            assertEquals(321, stored.configuration().profile("a").config().maxStreams());
            assertEquals(configuration().local().values().getProperty("routesInline"), stored.configuration().local().values().getProperty("routesInline"));
            assertEquals("direct 0:0:0:0:0:0:0:1\nproxy www.example.com", stored.configuration().local().get("routesOverrides", ""));
            assertEquals(12345, stored.configuration().local().integer("port", 0, 0, 65535));
            assertThrows(IOException.class, () -> new KernelDatabase(file));
        }
    }

    @Test
    void symbolicAliasCannotBypassExclusiveDatabaseLock() throws Exception {
        Path file = directory.resolve("kernel.db"), alias = directory.resolve("alias.db");
        try (var database = new KernelDatabase(file)) {
            try {
                Files.createSymbolicLink(alias, file);
            } catch (FileSystemException failure) {
                // Windows 的普通会话可能没有创建符号链接的权限，其他配置恢复检查仍独立执行。
                org.junit.jupiter.api.Assumptions.assumeFalse(System.getProperty("os.name").startsWith("Windows"),
                        "当前 Windows 会话不能创建符号链接");
                throw failure;
            }
            assertThrows(IOException.class, () -> new KernelDatabase(alias));
        }
    }

    @Test
    void unfinishedAndRejectedTransactionsPreservePreviousSnapshot() throws Exception {
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) {
            database.stage(configuration(), 0);
            database.commit();
            database.stage(new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(), ""), 1);
            // 关闭连接应撤销尚未提交的事务。
        }
        try (var database = new KernelDatabase(file)) {
            assertEquals(1, database.read().revision());
            assertEquals("a", database.read().configuration().defaultConnectionId());
            assertThrows(SQLException.class, () -> database.stage(configuration(), 0));
            database.rollback();
            assertEquals(1, database.read().revision());
            database.stage(new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(), ""), 1);
            database.commit();
            assertTrue(database.read().configuration().connections().isEmpty());
        }
    }

    @Test
    void corruptAndUnknownVersionFilesAreNeverReset() throws Exception {
        Path corrupt = directory.resolve("corrupt.db");
        Files.writeString(corrupt, "不是数据库");
        assertThrows(IOException.class, () -> new KernelDatabase(corrupt));
        assertEquals("不是数据库", Files.readString(corrupt));
        Path newer = directory.resolve("newer.db");
        try (var database = new KernelDatabase(newer)) {
            database.stage(configuration(), 0);
            database.commit();
        }
        try (var connection = com.blacicada.io.SQLiteTestSupport.open(newer); var statement = connection.createStatement()) {
            statement.execute("PRAGMA user_version=99");
        }
        byte[] before = Files.readAllBytes(newer);
        assertThrows(IOException.class, () -> new KernelDatabase(newer));
        assertArrayEquals(before, Files.readAllBytes(newer));
    }

    private Map<String, Object> minute(String session, long time, long sent, long received) {
        return Map.of("sessionId", session, "minuteStart", time, "activeDurationMillis", 30_000L,
                "sentBytes", sent, "receivedBytes", received);
    }

    @Test
    void summariesAddMinuteDeltasAcrossRestartsAndRetriesWithoutReadingOldTable() throws Exception {
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file); var connection = com.blacicada.io.SQLiteTestSupport.open(file);
             var sql = connection.createStatement()) {
            // 故意保留不同结构的旧表；新的查询不能读取、修改或删除它。
            sql.execute("CREATE TABLE traffic_samples (original TEXT)");
            sql.execute("INSERT INTO traffic_samples VALUES('保留旧记录')");
            database.writeHistory(List.of(minute("甲", 0, 100, 1000), minute("甲", 60_000, 30, 40),
                    minute("甲", 120_000, 10, 100), minute("乙", 60_000, 25, 50),
                    minute("乙", 180_000, 0, 0), minute("乙", 300_000, 999, 999)), List.of());
            database.writeHistory(List.of(minute("甲", 60_000, 50, 100)), List.of());
            var result = database.trafficSeries(360_000L, java.time.ZoneOffset.UTC, false);
            assertEquals(1184L, result.get("sentBytes"));
            assertEquals(2249L, result.get("receivedBytes"));
            assertEquals(5L, result.get("recordCount"));
            var buckets = ((List<?>) result.get("buckets")).stream().map(item -> (Map<?, ?>) item).filter(item -> ((Number) item.get("from")).longValue() >= 60_000).toList();
            assertEquals(75L, ((Map<?, ?>) buckets.get(0)).get("sentBytes"));
            assertEquals(10L, ((Map<?, ?>) buckets.get(1)).get("sentBytes"));
            assertEquals(1L, ((Map<?, ?>) buckets.get(2)).get("recordCount"));
            assertEquals(0L, ((Map<?, ?>) buckets.get(3)).get("recordCount"));
            assertEquals(0L, ((Map<?, ?>) buckets.get(2)).get("sentBytes"));
            assertThrows(SQLException.class, () -> database.writeHistory(List.of(minute("无效", 60_001, 1, 1)), List.of()));
            try (var row = sql.executeQuery("SELECT sql FROM sqlite_master WHERE name='traffic_minutes'")) {
                assertTrue(row.next());
                assertTrue(row.getString(1).contains("minute_start"));
                assertTrue(row.getString(1).contains("按自然分钟合并业务流量"));
            }
        }
        try (var database = new KernelDatabase(file); var connection = com.blacicada.io.SQLiteTestSupport.open(file);
             var sql = connection.createStatement(); var rows = sql.executeQuery("SELECT original FROM traffic_samples")) {
            assertTrue(rows.next());
            assertEquals("保留旧记录", rows.getString(1));
            assertFalse(rows.next());
            assertEquals(1184L, database.trafficSeries(360_000L, java.time.ZoneOffset.UTC, false).get("sentBytes"));
        }
    }

    @Test
    void databaseJournalAndLockArePrivate() throws Exception {
        if (!directory.getFileSystem().supportedFileAttributeViews().contains("posix")) return;
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) {
            database.stage(configuration(), 0);
            for (String name : List.of("kernel.db", "kernel.db.lock", "kernel.db-journal")) {
                assertEquals("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(Files.getPosixFilePermissions(directory.resolve(name))));
            }
            database.rollback();
        }
    }
}
