package com.blacicada.io;

import java.io.IOException;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

/** 数据库存储是启动配置；凭据不进入代理配置、管理 API 或日志。 */
public final class StorageConfig {
    public enum Type { SQLITE, POSTGRESQL, MYSQL }
    private final Type type;
    private final Path directory, file;
    private final String url;
    private final Properties credentials;

    private StorageConfig(Type type, Path directory, Path file, String url, Properties credentials) {
        this.type = type; this.directory = directory; this.file = file;
        this.url = url; this.credentials = credentials;
    }
    public static StorageConfig sqlite(Path file) {
        Path absolute = file.toAbsolutePath().normalize();
        return new StorageConfig(Type.SQLITE, absolute.getParent(), absolute, null, new Properties());
    }
    public static StorageConfig load(Path file) throws IOException {
        Path absolute = file.toAbsolutePath().normalize();
        Properties values = new Properties();
        try (var reader = Files.newBufferedReader(absolute)) { values.load(reader); }
        return parse(values, absolute.getParent(), System.getenv());
    }
    static StorageConfig parse(Properties values, Path directory, Map<String, String> environment) throws IOException {
        Type type;
        try { type = Type.valueOf(values.getProperty("type", "").trim().toUpperCase(Locale.ROOT)); }
        catch (IllegalArgumentException e) { throw new IOException("数据库 type 必须为 sqlite、postgresql 或 mysql"); }
        Set<String> allowed = type == Type.SQLITE ? Set.of("type", "path")
                : Set.of("type", "host", "port", "database", "username", "password", "passwordEnv", "sslMode");
        for (String key : values.stringPropertyNames())
            if (!allowed.contains(key)) throw new IOException("数据库配置包含不支持的字段");
        if (type == Type.SQLITE) return sqlite(directory.resolve(required(values, "path")));
        String host = required(values, "host"), database = required(values, "database");
        // 只构造单主机 URL，不允许在地址中注入凭据、自动重连或驱动参数。
        if (!host.matches("[a-zA-Z0-9._:-]+") || !database.matches("[a-zA-Z0-9_-]+"))
            throw new IOException("数据库 host 或 database 格式无效；IPv6 地址无需方括号");
        int port;
        try { port = Integer.parseInt(values.getProperty("port", type == Type.POSTGRESQL ? "5432" : "3306")); }
        catch (NumberFormatException e) { throw new IOException("数据库端口无效"); }
        if (port < 1 || port > 65535) throw new IOException("数据库端口无效");
        Properties credentials = new Properties();
        credentials.setProperty("user", required(values, "username"));
        if (values.containsKey("password") && values.containsKey("passwordEnv"))
            throw new IOException("password 与 passwordEnv 不能同时设置");
        String password = values.containsKey("passwordEnv") ? environment.get(required(values, "passwordEnv")) : values.getProperty("password");
        if (password == null) throw new IOException("未设置数据库密码或密码环境变量不存在");
        credentials.setProperty("password", password);
        String mode = values.getProperty("sslMode", "verify-full");
        if (!Set.of("verify-full", "disable").contains(mode)) throw new IOException("sslMode 必须为 verify-full 或 disable");
        if (type == Type.POSTGRESQL) {
            credentials.setProperty("sslmode", mode);
            credentials.setProperty("connectTimeout", "5");
            credentials.setProperty("socketTimeout", "10");
            credentials.setProperty("ApplicationName", "Network 内核");
        } else {
            credentials.setProperty("sslMode", mode.equals("disable") ? "DISABLED" : "VERIFY_IDENTITY");
            credentials.setProperty("connectTimeout", "5000");
            credentials.setProperty("socketTimeout", "10000");
            credentials.setProperty("autoReconnect", "false");
            credentials.setProperty("characterEncoding", "UTF-8");
        }
        String address = host.contains(":") ? "[" + host + "]" : host;
        return new StorageConfig(type, directory.toAbsolutePath().normalize(), null,
                "jdbc:" + type.name().toLowerCase(Locale.ROOT) + "://" + address + ":" + port + "/" + database, credentials);
    }
    private static String required(Properties values, String key) throws IOException {
        String value = values.getProperty(key, "").trim();
        if (value.isEmpty()) throw new IOException("缺少数据库配置：" + key);
        return value;
    }
    public Type type() { return type; }
    public Path directory() { return directory; }
    Path file() { return file; }
    Connection connect() throws SQLException { return DriverManager.getConnection(url, credentials); }
}
