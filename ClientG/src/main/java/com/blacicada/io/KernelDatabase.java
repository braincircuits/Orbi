package com.blacicada.io;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.DirectRoutes;
import com.blacicada.config.KernelConfig;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.sql.*;
import java.util.*;

/** 内核独占的 JDBC 存储；调用方串行协调数据库事务与运行配置。 */
public final class KernelDatabase implements AutoCloseable {
    private static final int APPLICATION_ID = 0x4e455457;
    private final Path file, directory;
    private final StorageConfig.Type type;
    private FileChannel lockChannel;
    private FileLock lock;
    private Connection connection;

    public record Snapshot(KernelConfig configuration, long revision) { }

    public KernelDatabase(Path path) throws IOException { this(StorageConfig.sqlite(path)); }

    public KernelDatabase(StorageConfig config) throws IOException {
        type = config.type();
        if (type != StorageConfig.Type.SQLITE) {
            file = null;
            directory = config.directory();
            try {
                connection = config.connect();
                openRemote();
                initializeMinutes();
            } catch (Exception e) {
                try { close(); } catch (RuntimeException ignored) { }
                // JDBC 异常可能包含连接参数，不将原始异常附加到启动输出。
                String detail = e instanceof IOException ? e.getMessage() : "请检查网络、数据库权限、TLS 和连接配置";
                throw new IOException("无法打开 " + backend() + " 内核数据库；" + detail);
            }
            return;
        }
        Path absolute = config.file().toAbsolutePath().normalize();
        Files.createDirectories(absolute.getParent());
        file = Files.exists(absolute) ? absolute.toRealPath() : absolute.getParent().toRealPath().resolve(absolute.getFileName());
        directory = file.getParent();
        try {
            Path lockFile = file.resolveSibling(file.getFileName() + ".lock");
            createPrivate(lockFile);
            lockChannel = FileChannel.open(lockFile, StandardOpenOption.WRITE);
            try { lock = lockChannel.tryLock(); }
            catch (OverlappingFileLockException e) { throw new IOException("数据库已被其他内核实例占用", e); }
            if (lock == null) throw new IOException("数据库已被其他内核实例占用");
            boolean fresh = !Files.exists(file);
            createPrivate(file);
            connection = DriverManager.getConnection("jdbc:sqlite:" + file);
            execute("PRAGMA busy_timeout=3000");
            execute("PRAGMA foreign_keys=ON");
            if (!fresh && (number("PRAGMA application_id") != APPLICATION_ID || number("PRAGMA user_version") != 1))
                throw new IOException("不是当前版本的内核数据库，不支持读取或迁移");
            // 预先保护回滚日志并重复使用，Windows 上也不依赖父目录的继承权限。
            createPrivate(file.resolveSibling(file.getFileName() + "-journal"));
            execute("PRAGMA journal_mode=TRUNCATE");
            execute("PRAGMA synchronous=FULL");
            if (fresh) initialize();
            initializeHistory();
            initializeMinutes();
        } catch (Exception e) {
            try { close(); } catch (RuntimeException cleanup) { e.addSuppressed(cleanup); }
            throw new IOException("无法打开内核数据库：" + file + "；" + (e instanceof IOException ? e.getMessage() : "请检查文件格式、权限或占用情况"), e);
        }
    }

    /** 远程库固定使用独占连接；连接丢失后须重启，不自动重连后继续使用失效的会话锁。 */
    private void openRemote() throws SQLException, IOException {
        var metadata = connection.getMetaData();
        if (type == StorageConfig.Type.POSTGRESQL) {
            if (metadata.getDatabaseMajorVersion() < 14) throw new IOException("需要 PostgreSQL 14 或更高版本");
            execute("SET search_path TO public");
            execute("SET statement_timeout TO 10000");
            execute("SET lock_timeout TO 3000");
            if (number("SELECT CASE WHEN pg_try_advisory_lock(1313166423,1) THEN 1 ELSE 0 END") != 1)
                throw new IOException("数据库已被其他内核实例占用");
        } else {
            if (!metadata.getDatabaseProductName().equals("MySQL") || metadata.getDatabaseMajorVersion() < 8
                    || metadata.getDatabaseMajorVersion() == 8 && metadata.getDatabaseMinorVersion() < 4)
                throw new IOException("需要 MySQL 8.4 或更高版本");
            execute("SET SESSION innodb_lock_wait_timeout=3");
            execute("SET SESSION sql_mode='STRICT_ALL_TABLES,ONLY_FULL_GROUP_BY,NO_ENGINE_SUBSTITUTION'");
            if (number("SELECT GET_LOCK(CONCAT('network:',SHA2(DATABASE(),224)),0)") != 1)
                throw new IOException("数据库已被其他内核实例占用");
        }
        Set<String> tables = new HashSet<>();
        String catalog = type == StorageConfig.Type.MYSQL ? connection.getCatalog() : null;
        String schema = type == StorageConfig.Type.POSTGRESQL ? "public" : null;
        try (var rows = metadata.getTables(catalog, schema, "%", new String[]{"TABLE", "VIEW"})) {
            while (rows.next()) tables.add(rows.getString("TABLE_NAME"));
        }
        if (tables.isEmpty()) initializeRemote();
        else {
            Set<String> expected = Set.of("storage_format", "metadata", "settings", "profiles", "profile_settings",
                    "routing", "target_routes", "access_records");
            // 旧流量表仅保留原数据，不读取、转换或继续写入。
            tables.remove("traffic_samples"); tables.remove("traffic_minutes");
            if (!tables.equals(expected)) throw new IOException("需要独立空库或完整的当前版本内核数据库，不自动修改其他表");
            if (number("SELECT application_id FROM storage_format WHERE id=1") != APPLICATION_ID
                    || number("SELECT version FROM storage_format WHERE id=1") != 1)
                throw new IOException("不是当前版本的内核数据库，不支持读取或迁移");
        }
    }

    private void initializeRemote() throws SQLException {
        boolean mysql = type == StorageConfig.Type.MYSQL;
        String text = mysql ? "LONGTEXT" : "TEXT";
        String identity = mysql ? "BIGINT PRIMARY KEY AUTO_INCREMENT" : "BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY";
        connection.setAutoCommit(false);
        try {
            remoteTable("metadata (id INTEGER PRIMARY KEY CHECK(id=1), revision BIGINT NOT NULL CHECK(revision>=0))");
            execute("INSERT INTO metadata VALUES(1,0)");
            remoteTable("settings (" + keyColumn() + " VARCHAR(255) PRIMARY KEY, value " + text + " NOT NULL)");
            remoteTable("profiles (id VARCHAR(255) PRIMARY KEY, name " + text + " NOT NULL, position INTEGER NOT NULL UNIQUE)");
            remoteTable("profile_settings (profile_id VARCHAR(255) NOT NULL, " + keyColumn() + " VARCHAR(255) NOT NULL, value " + text
                    + " NOT NULL, PRIMARY KEY(profile_id," + keyColumn() + "), FOREIGN KEY(profile_id) REFERENCES profiles(id) ON DELETE CASCADE)");
            remoteTable("routing (id INTEGER PRIMARY KEY CHECK(id=1), mode VARCHAR(16) NOT NULL CHECK(mode IN ('rules','direct','proxy')), default_profile_id VARCHAR(255), direct_rules "
                    + text + " NOT NULL, FOREIGN KEY(default_profile_id) REFERENCES profiles(id))");
            execute("INSERT INTO routing VALUES(1,'rules',NULL,'')");
            remoteTable("target_routes (host VARCHAR(255) PRIMARY KEY, route VARCHAR(16) NOT NULL CHECK(route IN ('direct','proxy')))");
            remoteTable("access_records (id " + identity + ", request_id VARCHAR(255) NOT NULL UNIQUE, session_id VARCHAR(255) NOT NULL, visited_at BIGINT NOT NULL, target " + text
                    + " NOT NULL, source " + text + " NOT NULL, method VARCHAR(32) NOT NULL, route VARCHAR(16) NOT NULL, protocol VARCHAR(32) NOT NULL, profile_id VARCHAR(255) NOT NULL, profile_name " + text + " NOT NULL, state VARCHAR(32) NOT NULL, completed_at BIGINT NOT NULL)");
            execute("CREATE INDEX access_records_time ON access_records(visited_at)");
            // MySQL 的 DDL 会隐式提交；最后写入格式标识，初始化中断的半成品库会被拒绝。
            remoteTable("storage_format (id INTEGER PRIMARY KEY CHECK(id=1), application_id INTEGER NOT NULL, version INTEGER NOT NULL)");
            execute("INSERT INTO storage_format VALUES(1," + APPLICATION_ID + ",1)");
            connection.commit();
        } catch (SQLException e) { rollbackFailure(e); throw e; }
        finally { if (!connection.isClosed()) connection.setAutoCommit(true); }
    }
    private void remoteTable(String definition) throws SQLException {
        execute("CREATE TABLE " + definition + (type == StorageConfig.Type.MYSQL ? " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin" : ""));
    }
    private String keyColumn() { return type == StorageConfig.Type.MYSQL ? "`key`" : "\"key\""; }
    public String backend() { return type.name().toLowerCase(Locale.ROOT); }
    public Path directory() { return directory; }

    private static void createPrivate(Path path) throws IOException {
        if (!Files.exists(path)) {
            try {
                if (path.getFileSystem().supportedFileAttributeViews().contains("posix"))
                    Files.createFile(path, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
                else Files.createFile(path);
            } catch (FileAlreadyExistsException ignored) { }
        }
        if (!Files.isRegularFile(path)) throw new IOException("数据库或锁路径不是普通文件：" + path);
        PrivateFiles.restrict(path);
    }

    private void initialize() throws SQLException {
        connection.setAutoCommit(false);
        try {
            execute("CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL CHECK(revision>=0))");
            execute("INSERT INTO metadata VALUES(1,0)");
            execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
            execute("CREATE TABLE profiles (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL UNIQUE)");
            execute("CREATE TABLE profile_settings (profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(profile_id,key))");
            execute("CREATE TABLE routing (id INTEGER PRIMARY KEY CHECK(id=1), mode TEXT NOT NULL CHECK(mode IN ('rules','direct','proxy')), default_profile_id TEXT REFERENCES profiles(id) DEFERRABLE INITIALLY DEFERRED, direct_rules TEXT NOT NULL)");
            execute("INSERT INTO routing VALUES(1,'rules',NULL,'')");
            execute("CREATE TABLE target_routes (host TEXT PRIMARY KEY, route TEXT NOT NULL CHECK(route IN ('direct','proxy')))");
            execute("PRAGMA application_id=" + APPLICATION_ID);
            execute("PRAGMA user_version=1");
            connection.commit();
        } catch (SQLException e) { rollbackFailure(e); throw e; }
        finally { if (!connection.isClosed()) connection.setAutoCommit(true); }
    }

    /** 扩展当前数据库的独立业务记录表，不改写配置和凭据。 */
    private void initializeHistory() throws SQLException {
        connection.setAutoCommit(false);
        try {
            execute("CREATE TABLE IF NOT EXISTS access_records (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL, visited_at INTEGER NOT NULL, target TEXT NOT NULL, source TEXT NOT NULL, method TEXT NOT NULL, route TEXT NOT NULL, protocol TEXT NOT NULL, profile_id TEXT NOT NULL, profile_name TEXT NOT NULL, state TEXT NOT NULL, completed_at INTEGER NOT NULL)");
            execute("CREATE INDEX IF NOT EXISTS access_records_time ON access_records(visited_at)");
            connection.commit();
        } catch (SQLException e) { rollbackFailure(e); throw e; }
        finally { if (!connection.isClosed()) connection.setAutoCommit(true); }
    }

    /** 分钟历史独立建表；不改写旧的秒级历史、配置和凭据。 */
    private void initializeMinutes() throws SQLException {
        try (var rows = connection.getMetaData().getTables(type == StorageConfig.Type.MYSQL ? connection.getCatalog() : null,
                type == StorageConfig.Type.POSTGRESQL ? "public" : null, "traffic_minutes", new String[]{"TABLE"})) {
            if (rows.next()) return;
        }
        String identity = switch (type) {
            case SQLITE -> "INTEGER PRIMARY KEY AUTOINCREMENT";
            case POSTGRESQL -> "BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY";
            case MYSQL -> "BIGINT PRIMARY KEY AUTO_INCREMENT";
        };
        var notes = Map.of("id", "分钟流量记录主键", "session_id", "本次代理服务运行的唯一标识",
                "minute_start", "统计分钟起点，Unix 毫秒", "active_duration_ms", "本次运行在该分钟内的统计时长，毫秒",
                "sent_bytes", "该分钟上传业务字节数，非启动累计值", "received_bytes", "该分钟下载业务字节数，非启动累计值");
        String description = "分钟业务流量统计，按运行会话与自然分钟保存增量";
        String definition = "traffic_minutes ( /* " + description + " */\n"
                + "id " + identity + columnNote(notes.get("id")) + ",\n"
                + "session_id VARCHAR(255) NOT NULL" + columnNote(notes.get("session_id")) + ",\n"
                + "minute_start BIGINT NOT NULL" + columnNote(notes.get("minute_start")) + ",\n"
                + "active_duration_ms BIGINT NOT NULL" + columnNote(notes.get("active_duration_ms")) + ",\n"
                + "sent_bytes BIGINT NOT NULL" + columnNote(notes.get("sent_bytes")) + ",\n"
                + "received_bytes BIGINT NOT NULL" + columnNote(notes.get("received_bytes")) + ",\n"
                + "CHECK(minute_start>=0 AND minute_start%60000=0), CHECK(active_duration_ms>=0 AND active_duration_ms<=60000), "
                + "CHECK(sent_bytes>=0), CHECK(received_bytes>=0), UNIQUE(session_id,minute_start)"
                + (type == StorageConfig.Type.MYSQL ? ", INDEX traffic_minutes_time(minute_start)) COMMENT='" + description + "'" : ")");
        connection.setAutoCommit(false);
        try {
            remoteTable(definition);
            if (type != StorageConfig.Type.MYSQL) execute("CREATE INDEX traffic_minutes_time ON traffic_minutes(minute_start)");
            if (type == StorageConfig.Type.POSTGRESQL) {
                execute("COMMENT ON TABLE traffic_minutes IS '" + description + "'");
                for (var entry : notes.entrySet())
                    execute("COMMENT ON COLUMN traffic_minutes." + entry.getKey() + " IS '" + entry.getValue() + "'");
            }
            connection.commit();
        } catch (SQLException e) { rollbackFailure(e); throw e; }
        finally { if (!connection.isClosed()) connection.setAutoCommit(true); }
    }
    private String columnNote(String note) {
        return type == StorageConfig.Type.MYSQL ? " COMMENT '" + note + "'" : " /* " + note + " */";
    }

    /** 在控制线程批量提交，不在 Netty 转发线程执行数据库操作；记录长期保留。 */
    public void writeHistory(List<Map<String, Object>> traffic, List<Map<String, Object>> access) throws SQLException {
        if (!connection.getAutoCommit()) throw new SQLException("配置事务尚未结束，不能写入历史记录");
        // SQLite 历史记录锁竞争立即返回；远程库由会话锁等待上限约束。
        if (type == StorageConfig.Type.SQLITE) execute("PRAGMA busy_timeout=0");
        connection.setAutoCommit(false);
        try {
            try (var insert = connection.prepareStatement("INSERT INTO traffic_minutes(session_id,minute_start,active_duration_ms,sent_bytes,received_bytes) VALUES(?,?,?,?,?)" + (type == StorageConfig.Type.MYSQL
                    ? " AS incoming ON DUPLICATE KEY UPDATE active_duration_ms=incoming.active_duration_ms,sent_bytes=incoming.sent_bytes,received_bytes=incoming.received_bytes"
                    : " ON CONFLICT(session_id,minute_start) DO UPDATE SET active_duration_ms=excluded.active_duration_ms,sent_bytes=excluded.sent_bytes,received_bytes=excluded.received_bytes"))) {
                for (var item : traffic) {
                    bind(insert, item, "sessionId", "minuteStart", "activeDurationMillis", "sentBytes", "receivedBytes"); insert.addBatch();
                }
                insert.executeBatch();
            }
            try (var insert = connection.prepareStatement("INSERT INTO access_records(request_id,session_id,visited_at,target,source,method,route,protocol,profile_id,profile_name,state,completed_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)" + (type == StorageConfig.Type.MYSQL
                    ? " AS incoming ON DUPLICATE KEY UPDATE route=incoming.route,protocol=incoming.protocol,profile_id=incoming.profile_id,profile_name=incoming.profile_name,state=incoming.state,completed_at=incoming.completed_at"
                    : " ON CONFLICT(request_id) DO UPDATE SET route=excluded.route,protocol=excluded.protocol,profile_id=excluded.profile_id,profile_name=excluded.profile_name,state=excluded.state,completed_at=excluded.completed_at"))) {
                for (var item : access) {
                    bind(insert, item, "requestId", "sessionId", "createdAt", "target", "source", "method", "route", "protocol", "profileId", "profileName", "state", "completedAt"); insert.addBatch();
                }
                insert.executeBatch();
            }
            connection.commit();
        } catch (SQLException e) { rollbackFailure(e); throw e; }
        finally { if (!connection.isClosed()) { connection.setAutoCommit(true); if (type == StorageConfig.Type.SQLITE) execute("PRAGMA busy_timeout=3000"); } }
    }
    private static void bind(PreparedStatement statement, Map<String, Object> item, String... keys) throws SQLException {
        for (int i = 0; i < keys.length; i++) statement.setObject(i + 1, item.get(keys[i]));
    }
    private static Map<String, Object> trafficRow(ResultSet row) throws SQLException {
        var item = new LinkedHashMap<String, Object>();
        item.put("id", row.getLong("id")); item.put("sessionId", row.getString("session_id"));
        item.put("minuteStart", row.getLong("minute_start")); item.put("activeDurationMillis", row.getLong("active_duration_ms"));
        item.put("sentBytes", row.getLong("sent_bytes")); item.put("receivedBytes", row.getLong("received_bytes"));
        return item;
    }
    public Map<String, Object> trafficHistory(long from, long to, long before, int limit, String session) throws SQLException {
        try (var query = connection.prepareStatement("SELECT * FROM traffic_minutes WHERE minute_start>=? AND minute_start<? AND id<? AND (?='' OR session_id=?) ORDER BY id DESC LIMIT ?")) {
            query.setLong(1, from); query.setLong(2, to); query.setLong(3, before); query.setString(4, session); query.setString(5, session); query.setInt(6, limit + 1);
            var items = new ArrayList<Map<String, Object>>();
            try (var rows = query.executeQuery()) { while (rows.next()) items.add(trafficRow(rows)); }
            return page(items, limit);
        }
    }
    /** 按查询边界汇总分钟增量；同一分钟内不同启动会话相加，旧秒级表不参与查询。 */
    public Map<String, Object> trafficSummary(List<Long> boundaries) throws SQLException {
        String cast = type == StorageConfig.Type.MYSQL ? "SIGNED" : "BIGINT";
        String values = String.join(" UNION ALL ", Collections.nCopies(boundaries.size() - 1,
                "SELECT CAST(? AS " + cast + "),CAST(? AS " + cast + "),CAST(? AS " + cast + ")"));
        String sql = """
                WITH buckets(bucket, range_start, range_end) AS (%s),
                grouped AS (
                    SELECT b.bucket, SUM(t.sent_bytes) AS sent, SUM(t.received_bytes) AS received,
                           COUNT(*) AS samples, MAX(t.minute_start) AS latest
                    FROM buckets b JOIN traffic_minutes t ON t.minute_start>=b.range_start AND t.minute_start<b.range_end
                    GROUP BY b.bucket
                )
                SELECT b.range_start, b.range_end, COALESCE(g.sent,0) AS sent,
                       COALESCE(g.received,0) AS received, COALESCE(g.samples,0) AS samples,
                       COALESCE(g.latest,0) AS latest
                FROM buckets b LEFT JOIN grouped g ON g.bucket=b.bucket ORDER BY b.bucket
                """.formatted(values);
        try (var query = connection.prepareStatement(sql)) {
            for (int i = 0; i < boundaries.size() - 1; i++) {
                query.setInt(i * 3 + 1, i); query.setLong(i * 3 + 2, boundaries.get(i)); query.setLong(i * 3 + 3, boundaries.get(i + 1));
            }
            var buckets = new ArrayList<Map<String, Object>>();
            long sent = 0, received = 0, samples = 0, latest = 0;
            try (var rows = query.executeQuery()) {
                while (rows.next()) {
                    long up = rows.getLong("sent"), down = rows.getLong("received"), count = rows.getLong("samples");
                    sent += up; received += down; samples += count; latest = Math.max(latest, rows.getLong("latest"));
                    buckets.add(Map.of("from", rows.getLong("range_start"), "to", rows.getLong("range_end"),
                            "sentBytes", up, "receivedBytes", down, "recordCount", count));
                }
            }
            return Map.of("buckets", buckets, "sentBytes", sent, "receivedBytes", received,
                    "recordCount", samples, "latestMinuteStart", latest);
        }
    }
    public Map<String, Object> accessHistory(long from, long to, long before, int limit, String target, String state) throws SQLException {
        String contains = type == StorageConfig.Type.POSTGRESQL ? "strpos(lower(target),lower(?))" : "instr(lower(target),lower(?))";
        try (var query = connection.prepareStatement("SELECT * FROM access_records WHERE visited_at>=? AND visited_at<? AND id<? AND " + contains + ">0 AND (?='' OR state=?) ORDER BY id DESC LIMIT ?")) {
            query.setLong(1, from); query.setLong(2, to); query.setLong(3, before); query.setString(4, target); query.setString(5, state); query.setString(6, state); query.setInt(7, limit + 1);
            var items = new ArrayList<Map<String, Object>>();
            try (var rows = query.executeQuery()) {
                while (rows.next()) {
                    var item = new LinkedHashMap<String, Object>();
                    item.put("id", rows.getLong("id")); item.put("requestId", rows.getString("request_id"));
                    item.put("sessionId", rows.getString("session_id")); item.put("createdAt", rows.getLong("visited_at"));
                    item.put("completedAt", rows.getLong("completed_at"));
                    for (String key : List.of("target", "source", "method", "route", "protocol", "state")) item.put(key, rows.getString(key));
                    item.put("profileId", rows.getString("profile_id")); item.put("profileName", rows.getString("profile_name"));
                    items.add(item);
                }
            }
            return page(items, limit);
        }
    }
    private static Map<String, Object> page(List<Map<String, Object>> items, int limit) {
        boolean more = items.size() > limit;
        if (more) items.removeLast();
        return Map.of("items", List.copyOf(items), "hasMore", more,
                "nextBeforeId", more ? items.getLast().get("id") : 0L);
    }
    public Snapshot read() throws IOException {
        try {
            Properties local = properties("SELECT " + keyColumn() + ",value FROM settings");
            String defaultId;
            try (var query = connection.createStatement(); var rows = query.executeQuery("SELECT * FROM routing WHERE id=1")) {
                if (!rows.next()) throw new SQLException("缺少路由设置");
                defaultId = Objects.requireNonNullElse(rows.getString("default_profile_id"), "");
                local.setProperty("routingMode", rows.getString("mode"));
                local.setProperty("routesInline", rows.getString("direct_rules"));
            }
            StringJoiner overrides = new StringJoiner("\n");
            try (var query = connection.createStatement(); var rows = query.executeQuery("SELECT host,route FROM target_routes ORDER BY host")) {
                while (rows.next()) overrides.add(rows.getString(2) + " " + rows.getString(1));
            }
            local.setProperty("routesOverrides", overrides.toString());
            List<KernelConfig.Profile> profiles = new ArrayList<>();
            try (var query = connection.createStatement(); var rows = query.executeQuery("SELECT id,name FROM profiles ORDER BY position")) {
                while (rows.next()) {
                    Properties values = new Properties();
                    try (var details = connection.prepareStatement("SELECT " + keyColumn() + ",value FROM profile_settings WHERE profile_id=?")) {
                        details.setString(1, rows.getString(1));
                        try (var fields = details.executeQuery()) { while (fields.next()) values.setProperty(fields.getString(1), fields.getString(2)); }
                    }
                    profiles.add(new KernelConfig.Profile(rows.getString(1), rows.getString(2), new ProxyConfig(values, directory)));
                }
            }
            return new Snapshot(new KernelConfig(new ProxyConfig(local, directory), profiles, defaultId),
                    number("SELECT revision FROM metadata WHERE id=1"));
        } catch (SQLException | IllegalArgumentException e) { throw new IOException("读取内核数据库失败，数据未被重置", e); }
    }

    /** 先写入未提交的候选快照，运行配置应用成功后由调用方提交。 */
    public void stage(KernelConfig next, long expected) throws SQLException, IOException {
        connection.setAutoCommit(false);
        try (var update = connection.prepareStatement("UPDATE metadata SET revision=revision+1 WHERE id=1 AND revision=?")) {
            update.setLong(1, expected);
            if (update.executeUpdate() != 1) throw new SQLException("数据库配置版本冲突");
        }
        execute("DELETE FROM target_routes");
        execute("UPDATE routing SET default_profile_id=NULL WHERE id=1");
        execute("DELETE FROM profiles");
        execute("DELETE FROM settings");
        Properties local = next.local().values();
        for (String key : List.of("routingMode", "routesInline", "routesOverrides")) local.remove(key);
        try (var insert = connection.prepareStatement("INSERT INTO settings VALUES(?,?)")) {
            for (String key : local.stringPropertyNames()) {
                insert.setString(1, key); insert.setString(2, local.getProperty(key)); insert.executeUpdate();
            }
        }
        try (var insert = connection.prepareStatement("INSERT INTO profiles VALUES(?,?,?)");
             var field = connection.prepareStatement("INSERT INTO profile_settings VALUES(?,?,?)")) {
            int position = 0;
            for (var profile : next.connections()) {
                insert.setString(1, profile.id()); insert.setString(2, profile.name()); insert.setInt(3, position++); insert.executeUpdate();
                Properties values = profile.config().values();
                for (String key : values.stringPropertyNames()) {
                    field.setString(1, profile.id()); field.setString(2, key); field.setString(3, values.getProperty(key)); field.executeUpdate();
                }
            }
        }
        DirectRoutes routes = DirectRoutes.load(next.local());
        try (var update = connection.prepareStatement("UPDATE routing SET mode=?,default_profile_id=?,direct_rules=? WHERE id=1")) {
            update.setString(1, next.routingMode());
            update.setString(2, next.defaultConnectionId().isEmpty() ? null : next.defaultConnectionId());
            update.setString(3, routes.text()); update.executeUpdate();
        }
        try (var insert = connection.prepareStatement("INSERT INTO target_routes VALUES(?,?)")) {
            for (var entry : routes.overrides().entrySet()) {
                insert.setString(1, entry.getKey()); insert.setString(2, entry.getValue()); insert.executeUpdate();
            }
        }
    }

    public void commit() throws SQLException { connection.commit(); connection.setAutoCommit(true); }
    public void rollback() throws SQLException {
        try {
            if (!connection.getAutoCommit()) { connection.rollback(); connection.setAutoCommit(true); }
        } catch (SQLException e) {
            // 回滚结果未知时关闭连接，禁止切回自动提交而意外提交剩余事务。
            try { connection.close(); } catch (SQLException close) { e.addSuppressed(close); }
            throw e;
        }
    }
    private void rollbackFailure(SQLException original) {
        try { rollback(); } catch (SQLException failure) { original.addSuppressed(failure); }
    }
    private void execute(String sql) throws SQLException { try (var statement = connection.createStatement()) { statement.execute(sql); } }
    private long number(String sql) throws SQLException {
        try (var query = connection.createStatement(); var rows = query.executeQuery(sql)) {
            if (!rows.next()) throw new SQLException("缺少数据库元数据");
            return rows.getLong(1);
        }
    }
    private Properties properties(String sql) throws SQLException {
        Properties values = new Properties();
        try (var query = connection.createStatement(); var rows = query.executeQuery(sql)) {
            while (rows.next()) values.setProperty(rows.getString(1), rows.getString(2));
        }
        return values;
    }

    @Override public void close() {
        try {
            if (connection != null && !connection.isClosed()) {
                try { if (!connection.getAutoCommit()) connection.rollback(); }
                finally { connection.close(); }
            }
        }
        catch (SQLException e) { throw new IllegalStateException("关闭内核数据库失败", e); }
        finally {
            try { if (lock != null) lock.release(); }
            catch (IOException e) { throw new IllegalStateException("释放数据库锁失败", e); }
            finally {
                try { if (lockChannel != null) lockChannel.close(); }
                catch (IOException e) { throw new IllegalStateException("关闭数据库锁文件失败", e); }
                // 锁文件保留，防止删除与其他进程获取锁之间发生竞争。
            }
        }
    }
}
