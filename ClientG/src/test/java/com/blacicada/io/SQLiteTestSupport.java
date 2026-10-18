package com.blacicada.io;

import java.nio.file.Path;
import java.sql.*;

/** 测试中的旁路连接与内核使用相同日志模式，避免 Windows 删除仍被内核持有的日志文件。 */
public final class SQLiteTestSupport {
    private SQLiteTestSupport() {}

    public static Connection open(Path file) throws SQLException {
        Connection connection = DriverManager.getConnection("jdbc:sqlite:" + file);
        try (var statement = connection.createStatement()) {
            statement.execute("PRAGMA journal_mode=TRUNCATE");
            return connection;
        } catch (SQLException failure) {
            connection.close();
            throw failure;
        }
    }
}
