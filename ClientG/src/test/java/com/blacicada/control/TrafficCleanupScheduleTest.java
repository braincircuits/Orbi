package com.blacicada.control;

import com.blacicada.io.KernelDatabase;

import java.nio.file.Path;
import java.sql.*;
import java.time.*;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class TrafficCleanupScheduleTest {
    @TempDir
    Path directory;

    static class MutableClock extends Clock {
        Instant now = Instant.parse("2026-10-14T18:59:00Z");

        @Override
        public ZoneId getZone() {
            return ZoneId.of("Asia/Shanghai");
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return Clock.fixed(now, zone);
        }

        @Override
        public Instant instant() {
            return now;
        }
    }

    @Test
    void cleansAtStartupAndLocalThreeAmWithCatchupAfterDowntime() throws Exception {
        var file = directory.resolve("schedule.db");
        var clock = new MutableClock();
        try (var db = new KernelDatabase(file); var connection = com.blacicada.io.SQLiteTestSupport.open(file); var sql = connection.createStatement()) {
            sql.execute("INSERT INTO traffic_hours VALUES(0,3600000,1,1,60000)");
            var history = new HistoryRecorder(db, clock);
            assertEquals(0, count(sql));
            sql.execute("INSERT INTO traffic_hours VALUES(0,3600000,1,1,60000)");
            history.tick();
            assertEquals(1, count(sql));
            clock.now = Instant.parse("2026-10-14T19:00:00Z");
            history.tick();
            assertEquals(0, count(sql));
            sql.execute("INSERT INTO traffic_hours VALUES(0,3600000,1,1,60000)");
            clock.now = Instant.parse("2026-10-14T20:00:00Z");
            history.tick();
            assertEquals(1, count(sql));
            new HistoryRecorder(db, clock);
            assertEquals(0, count(sql));
        }
    }

    int count(Statement sql) throws SQLException {
        try (var rows = sql.executeQuery("SELECT COUNT(*) FROM traffic_hours")) {
            rows.next();
            return rows.getInt(1);
        }
    }
}
