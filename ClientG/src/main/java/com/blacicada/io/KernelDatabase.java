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

/** 内核独占的 SQLite 存储；调用方串行协调数据库事务与运行配置。 */
public final class KernelDatabase implements AutoCloseable {
    private static final int APPLICATION_ID = 0x4e455457;
    private final Path file;
    private FileChannel lockChannel;
    private FileLock lock;
    private Connection connection;

    public record Snapshot(KernelConfig configuration, long revision) { }

    public KernelDatabase(Path path) throws IOException {
        Path absolute = path.toAbsolutePath().normalize();
        Files.createDirectories(absolute.getParent());
        file = Files.exists(absolute) ? absolute.toRealPath() : absolute.getParent().toRealPath().resolve(absolute.getFileName());
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
        } catch (Exception e) {
            try { close(); } catch (RuntimeException cleanup) { e.addSuppressed(cleanup); }
            throw new IOException("无法打开内核数据库：" + file + "；" + (e instanceof IOException ? e.getMessage() : "请检查文件格式、权限或占用情况"), e);
        }
    }

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
        } catch (SQLException e) { connection.rollback(); throw e; }
        finally { connection.setAutoCommit(true); }
    }

    /** 扩展当前数据库的独立业务记录表，不改写配置和凭据。 */
    private void initializeHistory() throws SQLException {
        connection.setAutoCommit(false);
        try {
            execute("CREATE TABLE IF NOT EXISTS traffic_samples (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, started_at INTEGER NOT NULL, sampled_at INTEGER NOT NULL, sent_bytes INTEGER NOT NULL, received_bytes INTEGER NOT NULL, send_rate REAL NOT NULL, receive_rate REAL NOT NULL, UNIQUE(session_id,sampled_at))");
            execute("CREATE INDEX IF NOT EXISTS traffic_samples_time ON traffic_samples(sampled_at)");
            execute("CREATE TABLE IF NOT EXISTS access_records (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE, session_id TEXT NOT NULL, visited_at INTEGER NOT NULL, target TEXT NOT NULL, source TEXT NOT NULL, method TEXT NOT NULL, route TEXT NOT NULL, protocol TEXT NOT NULL, profile_id TEXT NOT NULL, profile_name TEXT NOT NULL, state TEXT NOT NULL, completed_at INTEGER NOT NULL)");
            execute("CREATE INDEX IF NOT EXISTS access_records_time ON access_records(visited_at)");
            connection.commit();
        } catch (SQLException e) { connection.rollback(); throw e; }
        finally { connection.setAutoCommit(true); }
    }

    /** 在控制线程批量提交，不在 Netty 转发线程执行磁盘操作；记录长期保留。 */
    public void writeHistory(List<Map<String, Object>> traffic, List<Map<String, Object>> access) throws SQLException {
        if (!connection.getAutoCommit()) throw new SQLException("配置事务尚未结束，不能写入历史记录");
        // 历史记录锁竞争立即返回，下次重试，避免拖慢配置命令。
        execute("PRAGMA busy_timeout=0");
        connection.setAutoCommit(false);
        try {
            try (var insert = connection.prepareStatement("INSERT INTO traffic_samples(session_id,started_at,sampled_at,sent_bytes,received_bytes,send_rate,receive_rate) VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,sampled_at) DO NOTHING")) {
                for (var item : traffic) {
                    bind(insert, item, "sessionId", "startedAt", "sampledAt", "sentBytes", "receivedBytes", "sendBytesPerSecond", "receiveBytesPerSecond"); insert.addBatch();
                }
                insert.executeBatch();
            }
            try (var insert = connection.prepareStatement("INSERT INTO access_records(request_id,session_id,visited_at,target,source,method,route,protocol,profile_id,profile_name,state,completed_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(request_id) DO UPDATE SET route=excluded.route,protocol=excluded.protocol,profile_id=excluded.profile_id,profile_name=excluded.profile_name,state=excluded.state,completed_at=excluded.completed_at")) {
                for (var item : access) {
                    bind(insert, item, "requestId", "sessionId", "createdAt", "target", "source", "method", "route", "protocol", "profileId", "profileName", "state", "completedAt"); insert.addBatch();
                }
                insert.executeBatch();
            }
            connection.commit();
        } catch (SQLException e) { connection.rollback(); throw e; }
        finally { connection.setAutoCommit(true); execute("PRAGMA busy_timeout=3000"); }
    }
    private static void bind(PreparedStatement statement, Map<String, Object> item, String... keys) throws SQLException {
        for (int i = 0; i < keys.length; i++) statement.setObject(i + 1, item.get(keys[i]));
    }
    private static Map<String, Object> trafficRow(ResultSet row) throws SQLException {
        var item = new LinkedHashMap<String, Object>();
        item.put("id", row.getLong("id")); item.put("sessionId", row.getString("session_id"));
        item.put("startedAt", row.getLong("started_at")); item.put("sampledAt", row.getLong("sampled_at"));
        item.put("sentBytes", row.getLong("sent_bytes")); item.put("receivedBytes", row.getLong("received_bytes"));
        item.put("sendBytesPerSecond", row.getDouble("send_rate")); item.put("receiveBytesPerSecond", row.getDouble("receive_rate"));
        return item;
    }
    public Map<String, Object> trafficHistory(long from, long to, long before, int limit, String session) throws SQLException {
        try (var query = connection.prepareStatement("SELECT * FROM traffic_samples WHERE sampled_at>=? AND sampled_at<? AND id<? AND (?='' OR session_id=?) ORDER BY id DESC LIMIT ?")) {
            query.setLong(1, from); query.setLong(2, to); query.setLong(3, before); query.setString(4, session); query.setString(5, session); query.setInt(6, limit + 1);
            var items = new ArrayList<Map<String, Object>>();
            try (var rows = query.executeQuery()) { while (rows.next()) items.add(trafficRow(rows)); }
            return page(items, limit);
        }
    }
    /** 按本地日历边界汇总累计计数差值；增量归入采样时间所在区间，跨启动分别相减后相加。 */
    public Map<String, Object> trafficSummary(List<Long> boundaries) throws SQLException {
        String values = String.join(",", Collections.nCopies(boundaries.size() - 1, "(?,?,?)"));
        String sql = """
                WITH buckets(bucket, start, end) AS (VALUES %s),
                grouped AS (
                    SELECT b.bucket, t.session_id, MIN(t.sampled_at) AS first_at,
                           MAX(t.sent_bytes) AS sent, MAX(t.received_bytes) AS received,
                           COUNT(*) AS samples, MAX(t.sampled_at) AS latest
                    FROM buckets b JOIN traffic_samples t ON t.sampled_at>=b.start AND t.sampled_at<b.end
                    GROUP BY b.bucket, t.session_id
                ), deltas AS (
                    SELECT bucket, samples, latest,
                           sent-COALESCE((SELECT sent_bytes FROM traffic_samples p WHERE p.session_id=g.session_id AND p.sampled_at<g.first_at ORDER BY p.sampled_at DESC LIMIT 1),0) AS sent,
                           received-COALESCE((SELECT received_bytes FROM traffic_samples p WHERE p.session_id=g.session_id AND p.sampled_at<g.first_at ORDER BY p.sampled_at DESC LIMIT 1),0) AS received
                    FROM grouped g
                )
                SELECT b.start, b.end, COALESCE(SUM(d.sent),0) AS sent,
                       COALESCE(SUM(d.received),0) AS received, COALESCE(SUM(d.samples),0) AS samples,
                       COALESCE(MAX(d.latest),0) AS latest
                FROM buckets b LEFT JOIN deltas d ON d.bucket=b.bucket GROUP BY b.bucket ORDER BY b.bucket
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
                    buckets.add(Map.of("from", rows.getLong("start"), "to", rows.getLong("end"),
                            "sentBytes", up, "receivedBytes", down, "sampleCount", count));
                }
            }
            return Map.of("buckets", buckets, "sentBytes", sent, "receivedBytes", received,
                    "sampleCount", samples, "lastSampledAt", latest);
        }
    }
    public Map<String, Object> accessHistory(long from, long to, long before, int limit, String target) throws SQLException {
        try (var query = connection.prepareStatement("SELECT * FROM access_records WHERE visited_at>=? AND visited_at<? AND id<? AND instr(lower(target),lower(?))>0 ORDER BY id DESC LIMIT ?")) {
            query.setLong(1, from); query.setLong(2, to); query.setLong(3, before); query.setString(4, target); query.setInt(5, limit + 1);
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
    /** 内核重开且代理尚未启动时，展示最近一次启动的最后五分钟。 */
    public Map<String, Object> latestTraffic() throws SQLException {
        Map<String, Object> latest;
        try (var query = connection.createStatement(); var rows = query.executeQuery("SELECT * FROM traffic_samples ORDER BY id DESC LIMIT 1")) {
            if (!rows.next()) return null;
            latest = trafficRow(rows);
        }
        var history = new ArrayList<Map<String, Object>>();
        try (var query = connection.prepareStatement("SELECT * FROM traffic_samples WHERE session_id=? AND sampled_at>=? ORDER BY sampled_at DESC LIMIT 301")) {
            query.setString(1, (String) latest.get("sessionId")); query.setLong(2, ((Number) latest.get("sampledAt")).longValue() - 300_000);
            try (var rows = query.executeQuery()) { while (rows.next()) history.add(trafficRow(rows)); }
        }
        Collections.reverse(history); latest.put("history", List.copyOf(history));
        // 已结束的内核没有实时速率，保留曲线中的原始采样。
        latest.put("sendBytesPerSecond", 0.0); latest.put("receiveBytesPerSecond", 0.0);
        return Collections.unmodifiableMap(latest);
    }

    public Path file() { return file; }

    public Snapshot read() throws IOException {
        try {
            Properties local = properties("SELECT key,value FROM settings");
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
                    try (var details = connection.prepareStatement("SELECT key,value FROM profile_settings WHERE profile_id=?")) {
                        details.setString(1, rows.getString(1));
                        try (var fields = details.executeQuery()) { while (fields.next()) values.setProperty(fields.getString(1), fields.getString(2)); }
                    }
                    profiles.add(new KernelConfig.Profile(rows.getString(1), rows.getString(2), new ProxyConfig(values, file.getParent())));
                }
            }
            return new Snapshot(new KernelConfig(new ProxyConfig(local, file.getParent()), profiles, defaultId),
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
        if (!connection.getAutoCommit()) { connection.rollback(); connection.setAutoCommit(true); }
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
        try { if (connection != null) connection.close(); }
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
