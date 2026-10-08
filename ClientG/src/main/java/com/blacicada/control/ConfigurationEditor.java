package com.blacicada.control;

import com.blacicada.config.KernelConfig;
import com.google.gson.*;
import java.nio.file.Path;
import java.util.UUID;

/** 配置编辑与校验：构造候选快照，不启动代理、不保存文件、不推进版本。 */
final class ConfigurationEditor {
    record Created(String id, KernelConfig configuration) { }
    private final Path directory;
    ConfigurationEditor(Path directory) { this.directory = directory; }
    static KernelConfig.Profile find(KernelConfig config, String id) {
        return config.connections().stream().filter(p -> p.id().equals(id)).findFirst()
                .orElseThrow(() -> new ControlException(404, "PROFILE_NOT_FOUND", "连接配置不存在", "profileId"));
    }
    KernelConfig parse(JsonObject input, KernelConfig config) {
        JsonObject copy = input.deepCopy();
        if (copy.has("connections")) for (JsonElement element : copy.getAsJsonArray("connections")) {
            JsonObject item = element.getAsJsonObject(), values = item.getAsJsonObject("config");
            String id = item.has("id") ? item.get("id").getAsString() : "";
            if (values != null && !values.has("password")) config.connections().stream().filter(p -> p.id().equals(id)).findFirst()
                    .ifPresent(old -> values.addProperty("password", old.config().required("password")));
        }
        try { return KernelConfig.parse(copy, directory); }
        catch (IllegalArgumentException | IllegalStateException | NullPointerException e) {
            String message = e.getMessage() == null ? "" : e.getMessage();
            if (message.contains("协议、服务器地址和端口重复")) throw new ControlException(409, "PROFILE_DUPLICATE", "协议、服务器地址和端口重复", "connections");
            throw new ControlException(400, "INVALID_CONFIGURATION", "配置结构、字段或规则无效，请检查连接参数与证书", "configuration");
        }
    }
    Created create(KernelConfig current, JsonObject item) {
        JsonObject copy = item.deepCopy();
        String id = copy.has("id") ? copy.get("id").getAsString() : UUID.randomUUID().toString();
        if (current.connections().stream().anyMatch(p -> p.id().equals(id)))
            throw new ControlException(409, "PROFILE_ID_EXISTS", "连接 ID 已存在", "id");
        copy.addProperty("id", id);
        JsonObject root = current.json(true); root.getAsJsonArray("connections").add(copy);
        if (current.connections().isEmpty()) root.addProperty("defaultConnectionId", id);
        return new Created(id, parse(root, current));
    }
    KernelConfig patchProfile(KernelConfig current, String id, JsonObject patch) {
        find(current, id);
        if (patch.has("id") && !id.equals(patch.get("id").getAsString()))
            throw new ControlException(400, "IMMUTABLE_ID", "连接 ID 不能修改", "id");
        JsonObject root = current.json(true);
        for (JsonElement element : root.getAsJsonArray("connections")) {
            JsonObject item = element.getAsJsonObject();
            if (item.get("id").getAsString().equals(id)) merge(item, patch);
        }
        return parse(root, current);
    }
    KernelConfig patchSettings(KernelConfig current, JsonObject patch) {
        JsonObject root = current.json(true);
        merge(root.getAsJsonObject("local"), patch);
        return parse(root, current);
    }
    private static void merge(JsonObject target, JsonObject patch) {
        for (var entry : patch.entrySet()) {
            if (entry.getValue().isJsonNull()) target.remove(entry.getKey());
            else if (entry.getValue().isJsonObject() && target.has(entry.getKey()) && target.get(entry.getKey()).isJsonObject())
                merge(target.getAsJsonObject(entry.getKey()), entry.getValue().getAsJsonObject());
            else target.add(entry.getKey(), entry.getValue().deepCopy());
        }
    }
}
