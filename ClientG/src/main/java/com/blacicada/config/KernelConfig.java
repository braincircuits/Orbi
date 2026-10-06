package com.blacicada.config;

import com.blacicada.common.h3.*;
import com.blacicada.h3.Http3Session;
import com.google.gson.*;
import io.netty.util.NetUtil;
import java.net.IDN;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.*;
import java.io.IOException;

/** 不可变配置快照；文件和控制接口使用相同的校验入口。 */
public record KernelConfig(ProxyConfig local, List<Profile> connections, String defaultConnectionId) {
    private static final Gson JSON = new GsonBuilder().setPrettyPrinting().create();
    private static final Set<String> CONNECTION_KEYS = Set.of("protocol", "server.host", "server.port", "username", "password",
            "tls.ca", "tls.serverName", "connectTimeoutMillis", "idleTimeoutSeconds", "maxStreams");
    public record Profile(String id, String name, ProxyConfig config) {
        public Profile {
            if (id == null || !id.matches("[A-Za-z0-9_.-]{1,64}")) throw new IllegalArgumentException("连接 ID 无效");
            if (name == null || name.isBlank()) throw new IllegalArgumentException("连接名称不能为空");
            String protocol = config.get("protocol", "http3");
            if (!Set.of("http2", "http3").contains(protocol)) throw new IllegalArgumentException("协议必须为 http2 或 http3");
            Properties normalized = config.values();
            normalized.setProperty("server.host", normalizedHost(config.required("server.host")));
            config = new ProxyConfig(normalized, config.base());
            config.integer("server.port", 4433, 1, 65535);
            ProxyCredentials.clientAuthorization(config);
            config.connectTimeoutMillis(); config.maxStreams(); config.idleTimeoutSeconds();
            if (!config.get("tls.ca", "").isEmpty() && !Files.isRegularFile(config.path("tls.ca", "")))
                throw new IllegalArgumentException("CA 证书文件不存在");
        }
        public String key() {
            return config.get("protocol", "http3") + ":" + normalizedHost(config.required("server.host")) + ":" + config.integer("server.port", 4433, 1, 65535);
        }
    }
    public KernelConfig {
        connections = List.copyOf(connections);
        if (connections.isEmpty() || connections.size() > 128) throw new IllegalArgumentException("连接配置数量必须为 1 至 128");
        Set<String> ids = new HashSet<>(), keys = new HashSet<>();
        for (Profile p : connections) {
            if (!ids.add(p.id())) throw new IllegalArgumentException("连接 ID 重复");
            if (!keys.add(p.key())) throw new IllegalArgumentException("协议、服务器地址和端口重复");
        }
        if (!ids.contains(defaultConnectionId)) throw new IllegalArgumentException("默认连接不存在");
        local.integer("port", 8080, 0, 65535); local.connectTimeoutMillis();
        try {
            if (local.values().containsKey("routesInline")) new com.blacicada.h3.DirectRoutes(local.get("routesInline", ""));
            else new com.blacicada.h3.DirectRoutes(local.path("routesFile", "pac.txt"));
        } catch (IOException e) { throw new IllegalArgumentException("直连规则无效", e); }
    }
    public Profile profile(String id) {
        return connections.stream().filter(p -> p.id().equals(id)).findFirst().orElseThrow(() -> new IllegalArgumentException("连接不存在"));
    }
    public KernelConfig select(String id) { return new KernelConfig(local, connections, id); }
    public KernelConfig upsert(Profile profile) {
        List<Profile> all = new ArrayList<>(connections);
        all.removeIf(p -> p.id().equals(profile.id())); all.add(profile);
        return new KernelConfig(local, all, defaultConnectionId);
    }
    public KernelConfig remove(String id) {
        profile(id);
        if (id.equals(defaultConnectionId)) throw new IllegalArgumentException("请先切换默认连接，再删除此配置");
        return new KernelConfig(local, connections.stream().filter(p -> !p.id().equals(id)).toList(), defaultConnectionId);
    }
    public static KernelConfig legacy(ProxyConfig config) throws IOException {
        Properties p = new Properties();
        for (String key : CONNECTION_KEYS) if (config.values().containsKey(key)) p.setProperty(key, config.values().getProperty(key));
        Authority address = Http3Session.serverAddress(config);
        p.setProperty("server.host", address.host()); p.setProperty("server.port", Integer.toString(address.port()));
        return new KernelConfig(config, List.of(new Profile("default", "默认连接", new ProxyConfig(p, config.base()))), "default");
    }
    public static KernelConfig load(Path file) throws IOException {
        if (!file.toString().endsWith(".json")) return legacy(ProxyConfig.load(file));
        return parse(JsonParser.parseString(Files.readString(file)).getAsJsonObject(), file.toAbsolutePath().getParent());
    }
    public static KernelConfig parse(JsonObject root, Path base) {
        if (root.get("version").getAsInt() != 1) throw new IllegalArgumentException("不支持的配置版本");
        List<Profile> profiles = new ArrayList<>();
        for (JsonElement e : root.getAsJsonArray("connections")) profiles.add(parseProfile(e.getAsJsonObject(), base, null));
        return new KernelConfig(new ProxyConfig(properties(root.getAsJsonObject("local")), base), profiles, root.get("defaultConnectionId").getAsString());
    }
    public static Profile parseProfile(JsonObject object, Path base, Profile previous) {
        Properties p = properties(object.getAsJsonObject("config"));
        for (String key : p.stringPropertyNames()) if (!CONNECTION_KEYS.contains(key)) throw new IllegalArgumentException("未知连接配置字段：" + key);
        if (!p.containsKey("password") && previous != null) p.setProperty("password", previous.config().required("password"));
        return new Profile(object.get("id").getAsString(), object.get("name").getAsString(), new ProxyConfig(p, base));
    }
    public static Properties properties(JsonObject object) {
        Properties p = new Properties();
        if (object != null) object.entrySet().forEach(e -> p.setProperty(e.getKey(), e.getValue().getAsString()));
        return p;
    }
    public JsonObject json(boolean secrets) {
        JsonObject root = new JsonObject(); root.addProperty("version", 1);
        Properties localValues = local.values();
        CONNECTION_KEYS.forEach(localValues::remove);
        localValues.remove("serversFile");
        if (localValues.containsKey("routesFile")) localValues.setProperty("routesFile", local.path("routesFile", "").toString());
        root.add("local", JSON.toJsonTree(localValues)); root.addProperty("defaultConnectionId", defaultConnectionId);
        JsonArray all = new JsonArray();
        for (Profile profile : connections) {
            JsonObject item = new JsonObject(); item.addProperty("id", profile.id()); item.addProperty("name", profile.name());
            Properties values = profile.config().values();
            if (!secrets) values.remove("password");
            if (values.containsKey("tls.ca")) values.setProperty("tls.ca", profile.config().path("tls.ca", "").toString());
            item.add("config", JSON.toJsonTree(values)); all.add(item);
        }
        root.add("connections", all); return root;
    }
    /** 写入同目录临时文件后原子替换，避免崩溃产生半份配置。 */
    public void save(Path file) throws IOException {
        Path absolute = file.toAbsolutePath();
        Path temp = Files.createTempFile(absolute.getParent(), ".network-", ".json");
        try {
            if (temp.getFileSystem().supportedFileAttributeViews().contains("posix"))
                Files.setPosixFilePermissions(temp, PosixFilePermissions.fromString("rw-------"));
            Files.writeString(temp, JSON.toJson(json(true)) + "\n");
            Files.move(temp, absolute, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temp); }
    }
    private static String normalizedHost(String input) {
        String host = input.trim();
        if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
        byte[] ip = NetUtil.createByteArrayFromIpAddressString(host);
        if (host.contains("%")) throw new IllegalArgumentException("暂不支持带作用域的 IPv6 地址");
        if (ip != null) return NetUtil.bytesToIpAddress(ip);
        if (host.contains(":") || host.contains("/") || host.isBlank()) throw new IllegalArgumentException("服务器地址无效");
        if (host.endsWith(".")) host = host.substring(0, host.length() - 1);
        return IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
    }
}
