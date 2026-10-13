package com.blacicada.io;

import com.blacicada.control.KernelControl;
import com.blacicada.control.web.WebApplication;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.junit.jupiter.api.Assertions.*;

class StorageConfigTest {
    @TempDir Path directory;

    @Test void sqlitePathsResolveAgainstStartupFileAndPreserveExistingStorage() throws Exception {
        Path file = directory.resolve("storage.properties");
        Files.writeString(file, "type=sqlite\npath=数据/kernel.db\n");
        var config = StorageConfig.load(file);
        assertEquals(directory.resolve("数据/kernel.db"), config.file());
        try (var control = new KernelControl(config)) {
            assertEquals("sqlite", control.info().get("storageBackend"));
        }
        try (var database = new KernelDatabase(directory.resolve("数据/kernel.db"))) {
            assertEquals(0, database.read().revision());
        }
        assertThrows(IllegalArgumentException.class, () -> WebApplication.run(new String[]{"--db", "unused.db", "--storage-config", file.toString()}));
    }

    @Test void invalidPropertiesCannotInjectDriverOptionsOrExposePasswords() throws Exception {
        Properties valid = remote("postgresql");
        valid.remove("password"); valid.setProperty("passwordEnv", "TEST_DB_SECRET");
        assertThrows(IOException.class, () -> StorageConfig.parse(valid, directory, Map.of()));
        assertEquals(StorageConfig.Type.POSTGRESQL, StorageConfig.parse(valid, directory, Map.of("TEST_DB_SECRET", "口令")).type());
        valid.setProperty("password", "不能泄漏");
        assertThrows(IOException.class, () -> StorageConfig.parse(valid, directory, Map.of("TEST_DB_SECRET", "口令")));
        for (var entry : Map.of("host", "localhost?password=不能泄漏", "port", "70000", "database", "kernel?autoReconnect=true",
                "sslMode", "prefer", "type", "unknown").entrySet()) {
            Properties values = remote("mysql"); values.setProperty(entry.getKey(), entry.getValue());
            var failure = assertThrows(IOException.class, () -> StorageConfig.parse(values, directory, Map.of()));
            assertFalse(failure.toString().contains("不能泄漏"));
        }
        Properties values = remote("mysql"); values.setProperty("autoReconnect", "true");
        assertThrows(IOException.class, () -> StorageConfig.parse(values, directory, Map.of()));
    }

    @Test void unreachableRemoteNeverCreatesSqliteOrPrintsCredentials() throws Exception {
        for (String type : List.of("postgresql", "mysql")) {
            Properties values = remote(type);
            // 保持回环端口被非监听套接字占用，使连接立即拒绝。
            try (var socket = new java.net.Socket()) {
                socket.bind(new java.net.InetSocketAddress("127.0.0.1", 0));
                values.setProperty("port", Integer.toString(socket.getLocalPort()));
                values.setProperty("sslMode", "disable");
                var config = StorageConfig.parse(values, directory, Map.of());
                var failure = assertThrows(IOException.class, () -> new KernelDatabase(config));
                assertTrue(failure.getMessage().contains(type));
                assertFalse(failure.toString().contains("不能泄漏"));
                assertNull(failure.getCause());
            }
        }
        try (var files = Files.list(directory)) { assertEquals(0, files.count()); }
    }
    private Properties remote(String type) {
        Properties values = new Properties();
        values.setProperty("type", type); values.setProperty("host", "127.0.0.1");
        values.setProperty("database", "network_test"); values.setProperty("username", "network");
        values.setProperty("password", "不能泄漏");
        return values;
    }
}
