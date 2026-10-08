package com.blacicada.common;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;

/** 启动时加载认证配置；账号模式与旧的共享密码模式互斥。 */
public final class ProxyCredentials {
    private final Map<String, String> tokens;
    private final boolean accounts;

    private ProxyCredentials(Map<String, String> tokens, boolean accounts) {
        this.tokens = Map.copyOf(tokens);
        this.accounts = accounts;
    }

    public static String clientAuthorization(ProxyConfig config) {
        String username = config.get("username", "");
        String password = config.required("password");
        return username.isEmpty() ? sharedToken(password) : accountToken(username, password);
    }

    public static ProxyCredentials loadServer(ProxyConfig config) throws IOException {
        if (config.get("usersFile", "").isEmpty()) {
            return new ProxyCredentials(Map.of("共享密码", sharedToken(config.required("password"))), false);
        }
        // 重复账号通常是配置错误，不能让后面的密码悄悄覆盖前面的密码。
        Properties users = new Properties() {
            @Override public synchronized Object put(Object key, Object value) {
                if (containsKey(key)) throw new IllegalArgumentException("账号文件中存在重复账号：" + key);
                return super.put(key, value);
            }
        };
        try (var reader = Files.newBufferedReader(config.path("usersFile", ""), StandardCharsets.UTF_8)) {
            users.load(reader);
        }
        if (users.isEmpty()) throw new IllegalArgumentException("账号文件不能为空");
        Map<String, String> tokens = new LinkedHashMap<>();
        for (String username : users.stringPropertyNames()) {
            String password = users.getProperty(username).trim();
            if (password.isEmpty()) throw new IllegalArgumentException("账号密码不能为空：" + username);
            tokens.put(username, accountToken(username, password));
        }
        return new ProxyCredentials(tokens, true);
    }

    private static String sharedToken(String password) {
        return "Bearer " + Base64.getEncoder().encodeToString(password.getBytes(StandardCharsets.UTF_8));
    }

    private static String accountToken(String username, String password) {
        if (!username.matches("[A-Za-z0-9][A-Za-z0-9_.-]{0,63}"))
            throw new IllegalArgumentException("账号名应为 1 至 64 位字母、数字、下划线、点或连字符，且以字母或数字开头");
        return "Basic " + Base64.getEncoder().encodeToString((username + ":" + password).getBytes(StandardCharsets.UTF_8));
    }

    /** 返回认证账号；认证失败返回 null，不记录密码或认证头。 */
    public String authenticate(CharSequence authorization) {
        if (authorization == null) return null;
        for (var entry : tokens.entrySet()) {
            if (MessageDigest.isEqual(entry.getValue().getBytes(StandardCharsets.UTF_8),
                    authorization.toString().getBytes(StandardCharsets.UTF_8))) return entry.getKey();
        }
        return null;
    }

    public String challenge() { return accounts ? "Basic realm=\"HTTP3 Proxy\", charset=\"UTF-8\"" : "Bearer"; }
}
