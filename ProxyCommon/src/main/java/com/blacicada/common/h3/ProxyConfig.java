package com.blacicada.common.h3;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/** 配置仅加载一次，在创建任何套接字或启动线程之前完成。 */
public final class ProxyConfig {
    private final Properties values;
    private final Path base;

    public ProxyConfig(Properties values, Path base) {
        this.values = new Properties();
        this.values.putAll(values);
        this.base = base.toAbsolutePath();
    }

    public static ProxyConfig load(Path file) throws IOException {
        Properties values = new Properties();
        try (var reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
            values.load(reader);
        }
        return new ProxyConfig(values, file.toAbsolutePath().getParent());
    }

    public String get(String name, String fallback) {
        return values.getProperty(name, fallback).trim();
    }

    public String required(String name) {
        String value = get(name, "");
        if (value.isEmpty()) throw new IllegalArgumentException("缺少配置：" + name);
        return value;
    }

    public int integer(String name, int fallback, int min, int max) {
        int value = Integer.parseInt(get(name, Integer.toString(fallback)));
        if (value < min || value > max) throw new IllegalArgumentException("配置无效：" + name);
        return value;
    }

    public Path path(String name, String fallback) {
        return base.resolve(get(name, fallback)).normalize();
    }

    public Properties values() { Properties copy = new Properties(); copy.putAll(values); return copy; }
    public Path base() { return base; }

    public int connectTimeoutMillis() { return integer("connectTimeoutMillis", 10000, 100, 120000); }
    public int maxStreams() { return integer("maxStreams", 256, 1, 10000); }
    public long idleTimeoutSeconds() { return integer("idleTimeoutSeconds", 300, 10, 86400); }
}
