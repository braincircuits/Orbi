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
    @TempDir Path directory;
    KernelConfig configuration() {
        Properties local = new Properties(), profile = new Properties();
        local.setProperty("bind", "127.0.0.1"); local.setProperty("port", "12345");
        local.setProperty("routingMode", "direct");
        local.setProperty("routesInline", " # 保留原文\r\nexample.com\r\n\r\n");
        local.setProperty("routesOverrides", "proxy www.example.com\ndirect ::1");
        profile.setProperty("protocol", "http2"); profile.setProperty("server.host", "localhost");
        profile.setProperty("password", "数据库测试凭据"); profile.setProperty("maxStreams", "321");
        return new KernelConfig(new ProxyConfig(local, directory), List.of(
                new KernelConfig.Profile("a", "测试连接", new ProxyConfig(profile, directory))), "a");
    }
    @Test void restartRestoresConfigurationVersionAndCredentials() throws Exception {
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) {
            assertEquals(0, database.read().revision());
            assertTrue(database.read().configuration().connections().isEmpty());
            database.stage(configuration(), 0); database.commit();
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
            Path alias = directory.resolve("alias.db"); Files.createSymbolicLink(alias, file);
            assertThrows(IOException.class, () -> new KernelDatabase(alias));
        }
    }
    @Test void unfinishedAndRejectedTransactionsPreservePreviousSnapshot() throws Exception {
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) {
            database.stage(configuration(), 0); database.commit();
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
    @Test void corruptAndUnknownVersionFilesAreNeverReset() throws Exception {
        Path corrupt = directory.resolve("corrupt.db");
        Files.writeString(corrupt, "不是数据库");
        assertThrows(IOException.class, () -> new KernelDatabase(corrupt));
        assertEquals("不是数据库", Files.readString(corrupt));
        Path newer = directory.resolve("newer.db");
        try (var database = new KernelDatabase(newer)) { database.stage(configuration(), 0); database.commit(); }
        try (var connection = DriverManager.getConnection("jdbc:sqlite:" + newer); var statement = connection.createStatement()) {
            statement.execute("PRAGMA user_version=99");
        }
        byte[] before = Files.readAllBytes(newer);
        assertThrows(IOException.class, () -> new KernelDatabase(newer));
        assertArrayEquals(before, Files.readAllBytes(newer));
    }
    private Map<String, Object> sample(String session, long time, long sent, long received) {
        return Map.of("sessionId", session, "startedAt", 0L, "sampledAt", time,
                "sentBytes", sent, "receivedBytes", received, "sendBytesPerSecond", 0.0, "receiveBytesPerSecond", 0.0);
    }
    @Test void summariesUseCounterDifferencesAcrossBoundariesRestartsAndEmptyBuckets() throws Exception {
        try (var database = new KernelDatabase(directory.resolve("kernel.db"))) {
            database.writeHistory(List.of(
                    sample("甲", 10, 100, 1000), sample("甲", 100, 130, 1040),
                    sample("甲", 199, 150, 1100), sample("甲", 200, 160, 1200),
                    sample("乙", 150, 0, 0), sample("乙", 190, 25, 50),
                    sample("乙", 300, 25, 50), sample("乙", 500, 999, 999)), List.of());
            var result = database.trafficSummary(List.of(100L, 200L, 300L, 400L, 500L));
            assertEquals(85L, result.get("sentBytes")); assertEquals(250L, result.get("receivedBytes"));
            assertEquals(6L, result.get("sampleCount")); assertEquals(300L, result.get("lastSampledAt"));
            var buckets = (List<?>) result.get("buckets");
            assertEquals(75L, ((Map<?, ?>) buckets.get(0)).get("sentBytes"));
            assertEquals(10L, ((Map<?, ?>) buckets.get(1)).get("sentBytes"));
            assertEquals(1L, ((Map<?, ?>) buckets.get(2)).get("sampleCount"));
            assertEquals(0L, ((Map<?, ?>) buckets.get(3)).get("sampleCount"));
            assertEquals(0L, ((Map<?, ?>) buckets.get(2)).get("sentBytes"));
            assertEquals(0L, database.trafficSummary(List.of(600L, 700L)).get("sampleCount"));
        }
    }
    @Test void databaseJournalAndLockArePrivate() throws Exception {
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
