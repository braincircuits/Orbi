package com.blacicada.control;

import com.blacicada.io.KernelDatabase;
import com.google.gson.JsonParser;

import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import java.util.concurrent.*;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

@Timeout(30)
class HistoryPersistenceTest {
    @TempDir
    Path directory;

    @SuppressWarnings("unchecked")
    private static List<Map<String, Object>> items(Map<String, Object> page) {
        return (List<Map<String, Object>>) page.get("items");
    }

    private static Map<String, Object> traffic(long time) {
        return Map.of("sessionId", "会话一", "minuteStart", time * 60_000, "activeDurationMillis", 60_000L,
                "sentBytes", 128L, "receivedBytes", 256L);
    }

    @Test
    void internalNetworkRestartKeepsSessionButUserRestartStartsAnother() throws Exception {
        try (var db = new KernelDatabase(directory.resolve("runtime.db"))) {
            var recorder = new HistoryRecorder(db);
            var properties = new Properties();
            properties.setProperty("routingMode", "direct");
            properties.setProperty("port", "0");
            var config = new com.blacicada.config.KernelConfig(new com.blacicada.common.ProxyConfig(properties, directory), List.of(), "");
            try (var runtime = new ProxyRuntime(recorder)) {
                runtime.start(config);
                String session = (String) runtime.traffic().get("sessionId");
                Object started = runtime.traffic().get("startedAt");
                // 使用默认出口重建监听即可验证生命周期，不修改系统路由或启动真实 TUN。
                runtime.bindInterface(0, config);
                assertEquals(session, runtime.traffic().get("sessionId"));
                assertEquals(started, runtime.traffic().get("startedAt"));
                runtime.stop();
                recorder.finish();
                assertEquals(session, runtime.traffic().get("sessionId"));
                assertTrue(((Number) db.trafficSeries(System.currentTimeMillis() + 60000, java.time.ZoneId.systemDefault(), false).get("recordCount")).longValue() > 0);
                runtime.start(config);
                assertNotEquals(session, runtime.traffic().get("sessionId"));
                assertEquals(0L, runtime.traffic().get("sentBytes"));
            }
        }
    }

    @Test
    void failedBatchRetriesWithoutLosingDataAndConfigurationRemainsIndependent() throws Exception {
        var path = directory.resolve("kernel.db");
        try (var db = new KernelDatabase(path); var external = com.blacicada.io.SQLiteTestSupport.open(path); var sql = external.createStatement()) {
            var recorder = new HistoryRecorder(db, java.time.Clock.fixed(java.time.Instant.ofEpochMilli(2_000_000L), java.time.ZoneOffset.UTC));
            recorder.traffic(traffic(10));
            sql.execute("CREATE TRIGGER reject_history BEFORE INSERT ON traffic_minutes BEGIN SELECT RAISE(FAIL, '测试写入失败'); END");
            assertFalse(recorder.flush());
            assertEquals(1, recorder.status().get("pendingRecords"));
            assertFalse(recorder.status().get("error").toString().isEmpty());
            assertEquals(0, db.read().revision());
            sql.execute("DROP TRIGGER reject_history");
            assertTrue(recorder.flush());
            recorder.traffic(traffic(10));
            recorder.traffic(traffic(20));
            recorder.traffic(traffic(30));
            recorder.finish();
            var result = db.trafficSeries(2_000_000L, java.time.ZoneOffset.UTC, false);
            assertEquals(3L, result.get("recordCount"));
            assertEquals(384L, result.get("sentBytes"));
        }
        try (var db = new KernelDatabase(path)) {
            assertEquals(384L, db.trafficSeries(2_000_000L, java.time.ZoneOffset.UTC, false).get("sentBytes"));
        }
    }

    @Test
    void requestAddressesAndTrafficSurviveKernelRestartWithoutCapturingUrlSecrets() throws Exception {
        var path = directory.resolve("kernel.db");
        String session;
        try (var origin = new ServerSocket(0, 10, InetAddress.getLoopbackAddress());
             var executor = Executors.newVirtualThreadPerTaskExecutor(); var control = new KernelControl(path)) {
            var server = executor.submit(() -> {
                try (var peer = origin.accept()) {
                    var input = peer.getInputStream();
                    int state = 0;
                    byte[] ending = {'\r', '\n', '\r', '\n'};
                    while (state < 4) {
                        int b = input.read();
                        if (b < 0) throw new java.io.EOFException();
                        state = b == ending[state] ? state + 1 : 0;
                    }
                    peer.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".getBytes(StandardCharsets.US_ASCII));
                }
                return null;
            });
            control.patchSettings(JsonParser.parseString("{\"routingMode\":\"direct\",\"port\":0}").getAsJsonObject(), 0);
            control.start();
            session = (String) control.traffic().get("sessionId");
            String address = (String) control.status().get("address");
            try (var browser = new Socket("127.0.0.1", Integer.parseInt(address.substring(address.lastIndexOf(':') + 1)))) {
                browser.setSoTimeout(5000);
                browser.getOutputStream().write(("GET http://localhost:" + origin.getLocalPort() + "/private?token=secret HTTP/1.1\r\nHost: localhost\r\nAuthorization: secret\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                assertTrue(new String(browser.getInputStream().readAllBytes(), StandardCharsets.US_ASCII).endsWith("ok"));
            }
            server.get(5, TimeUnit.SECONDS);
            int unavailable;
            try (var reservation = new ServerSocket(0)) {
                unavailable = reservation.getLocalPort();
            }
            try (var browser = new Socket("127.0.0.1", Integer.parseInt(address.substring(address.lastIndexOf(':') + 1)))) {
                browser.setSoTimeout(5000);
                browser.getOutputStream().write(("CONNECT localhost:" + unavailable + " HTTP/1.1\r\nHost: localhost\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                assertTrue(new String(browser.getInputStream().readAllBytes(), StandardCharsets.US_ASCII).startsWith("HTTP/1.1 502"));
            }
            control.stop();
            var records = items(control.history(100, "localhost", true, "recent", false, Long.MAX_VALUE, ""));
            assertEquals(1, records.size());
            var record = records.getFirst();
            assertEquals("localhost", record.get("host"));
            assertEquals(2L, record.get("connectionCount"));
            assertTrue(((Number) record.get("lastFailureAt")).longValue() > 0);
            assertFalse(record.toString().contains("secret"));
            assertFalse(record.toString().contains("/private"));
            assertTrue(((Number) control.traffic().get("sentBytes")).longValue() > 0);
            assertThrows(ControlException.class, () -> control.history(0, "", false, "recent", false, Long.MAX_VALUE, ""));
        }
        try (var control = new KernelControl(path)) {
            assertEquals("", control.traffic().get("sessionId"));
            assertEquals(1, items(control.history(100, "", false, "recent", false, Long.MAX_VALUE, "")).size());
            control.start();
            assertNotEquals(session, control.traffic().get("sessionId"));
            control.stop();
            assertEquals("minute", control.trafficSeries(false).get("interval"));
        }
    }
}
