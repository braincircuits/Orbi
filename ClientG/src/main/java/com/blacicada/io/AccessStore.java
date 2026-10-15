package com.blacicada.io;

import java.sql.*;
import java.util.*;

/** 域名累计统计与单个已提交批次标记；不保存逐连接明细。 */
final class AccessStore {
    private final Connection connection;
    private final boolean mysql;
    private final String contains;
    AccessStore(Connection connection, StorageConfig.Type type) throws SQLException {
        this.connection = connection; mysql = type == StorageConfig.Type.MYSQL;
        contains = type == StorageConfig.Type.POSTGRESQL ? "strpos(host,?)" : "instr(host,?)";
        try (var sql = connection.createStatement()) {
            String suffix = mysql ? " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin" : "";
            sql.execute("CREATE TABLE IF NOT EXISTS access_domains (host VARCHAR(255) NOT NULL PRIMARY KEY /* 规范化域名或IP */, connection_count BIGINT NOT NULL CHECK(connection_count>=0) /* 累计连接尝试次数 */, last_access_at BIGINT NOT NULL /* 最后发起时间 */, last_failure_at BIGINT NOT NULL /* 最后建立失败时间，0表示没有 */)" + suffix);
            sql.execute("CREATE TABLE IF NOT EXISTS access_flush (id INTEGER PRIMARY KEY CHECK(id=1), batch_id VARCHAR(64) NOT NULL /* 最后提交批次，防止不确定提交后的重复累计 */)" + suffix);
        }
        var indexes = new HashSet<String>();
        try (var rows = connection.getMetaData().getIndexInfo(mysql ? connection.getCatalog() : null,
                type == StorageConfig.Type.POSTGRESQL ? "public" : null, "access_domains", false, false)) {
            while (rows.next()) indexes.add(rows.getString("INDEX_NAME"));
        }
        try (var sql = connection.createStatement()) {
            if (!indexes.contains("access_domains_recent")) sql.execute("CREATE INDEX access_domains_recent ON access_domains(last_access_at DESC,host ASC)");
            if (!indexes.contains("access_domains_failure")) sql.execute("CREATE INDEX access_domains_failure ON access_domains(last_failure_at DESC,host ASC)");
            if (!indexes.contains("access_domains_count")) sql.execute("CREATE INDEX access_domains_count ON access_domains(connection_count DESC,host ASC)");
        }
    }
    void write(List<Map<String, Object>> values) throws SQLException {
        if (values.isEmpty()) return;
        String batch = (String) values.getFirst().get("batchId");
        if (batch == null || batch.isBlank()) throw new SQLException("访问统计批次标识无效");
        try (var sql = connection.createStatement(); var row = sql.executeQuery("SELECT batch_id FROM access_flush WHERE id=1")) {
            if (row.next() && batch.equals(row.getString(1))) return;
        }
        String update = mysql
                ? " AS incoming ON DUPLICATE KEY UPDATE connection_count=connection_count+incoming.connection_count,last_access_at=GREATEST(last_access_at,incoming.last_access_at),last_failure_at=GREATEST(last_failure_at,incoming.last_failure_at)"
                : " ON CONFLICT(host) DO UPDATE SET connection_count=access_domains.connection_count+excluded.connection_count,last_access_at=CASE WHEN access_domains.last_access_at>excluded.last_access_at THEN access_domains.last_access_at ELSE excluded.last_access_at END,last_failure_at=CASE WHEN access_domains.last_failure_at>excluded.last_failure_at THEN access_domains.last_failure_at ELSE excluded.last_failure_at END";
        try (var insert = connection.prepareStatement("INSERT INTO access_domains(host,connection_count,last_access_at,last_failure_at) VALUES(?,?,?,?)" + update)) {
            for (var value : values) {
                if (!batch.equals(value.get("batchId"))) throw new SQLException("访问统计批次不一致");
                insert.setString(1, (String) value.get("host"));
                insert.setLong(2, ((Number) value.get("connectionCount")).longValue());
                insert.setLong(3, ((Number) value.get("lastAccessAt")).longValue());
                insert.setLong(4, ((Number) value.get("lastFailureAt")).longValue()); insert.addBatch();
            }
            insert.executeBatch();
        }
        try (var insert = connection.prepareStatement("INSERT INTO access_flush(id,batch_id) VALUES(1,?)" + (mysql
                ? " AS incoming ON DUPLICATE KEY UPDATE batch_id=incoming.batch_id"
                : " ON CONFLICT(id) DO UPDATE SET batch_id=excluded.batch_id"))) {
            insert.setString(1, batch); insert.executeUpdate();
        }
    }
    Map<String, Object> read(int limit, String target, boolean failedOnly, String order, boolean ascending, long before, String afterHost) throws SQLException {
        String column = switch (order) {
            case "host" -> "host";
            case "count" -> "connection_count";
            case "recent" -> "last_access_at";
            case "failure" -> "last_failure_at";
            default -> throw new IllegalArgumentException("访问统计排序无效");
        };
        String field = switch (order) {
            case "count" -> "connectionCount";
            case "failure" -> "lastFailureAt";
            default -> "lastAccessAt";
        };
        String filter = target.toLowerCase(Locale.ROOT);
        try { filter = com.blacicada.config.DirectRoutes.normalizeHost(filter); }
        catch (IllegalArgumentException ignored) { /* 非完整目标按字面子串搜索。 */ }
        // 表头切换后从首行重新查询；后续页沿同一排序方向使用复合游标。
        boolean paged = !afterHost.isEmpty(), hostOrder = order.equals("host");
        String comparison = ascending ? ">" : "<";
        String cursor = !paged ? "" : hostOrder ? " AND host" + comparison + "?"
                : " AND (" + column + comparison + "? OR (" + column + "=? AND host>?))";
        String sql = "SELECT * FROM access_domains WHERE " + contains + ">0" + (failedOnly ? " AND last_failure_at>0" : "")
                + cursor + " ORDER BY " + column + (ascending ? " ASC" : " DESC") + (hostOrder ? "" : ",host ASC") + " LIMIT ?";
        var items = new ArrayList<Map<String, Object>>();
        try (var query = connection.prepareStatement(sql)) {
            int index = 1;
            query.setString(index++, filter);
            if (paged) {
                if (!hostOrder) { query.setLong(index++, before); query.setLong(index++, before); }
                query.setString(index++, afterHost);
            }
            query.setInt(index, limit + 1);
            try (var rows = query.executeQuery()) { while (rows.next()) items.add(Map.of("host", rows.getString("host"),
                    "connectionCount", rows.getLong("connection_count"), "lastAccessAt", rows.getLong("last_access_at"), "lastFailureAt", rows.getLong("last_failure_at"))); }
        }
        boolean more = items.size() > limit;
        if (more) items.removeLast();
        var last = items.isEmpty() ? Map.<String, Object>of() : items.getLast();
        return Map.of("items", List.copyOf(items), "hasMore", more,
                "nextValue", more && !hostOrder ? last.get(field) : 0L,
                "nextHost", more ? last.get("host") : "");
    }
}
