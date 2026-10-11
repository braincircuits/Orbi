package com.blacicada.control.web;

import com.blacicada.control.*;
import com.google.gson.JsonObject;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** 管理 API 的资源路由，不负责套接字、鉴权、响应写入或订阅生命周期。 */
final class ControlApi {
    record Response(int status, Map<String, Object> body, boolean shutdown) { }
    private final KernelControl control;
    ControlApi(KernelControl control) { this.control = control; }
    Response dispatch(String method, URI uri, JsonObject body, String ifMatch, String requestId) throws Exception {
        String path = uri.getPath();
        String action = method + " " + path;
        Object data; int status = 200;
        // 业务操作与响应快照使用同一把锁，防止响应数据和版本号属于不同次修改。
        synchronized (control) {
            switch (action) {
                case "GET /api/v1/info" -> data = control.info();
                case "GET /api/v1/health" -> data = Map.of("ready", true);
                case "GET /api/v1/status" -> data = control.status();
                case "GET /api/v1/traffic" -> data = control.traffic();
                case "GET /api/v1/traffic/history", "GET /api/v1/access-records" -> {
                    var query = query(uri);
                    boolean traffic = path.endsWith("/traffic/history");
                    data = control.history(traffic, Long.parseLong(query.getOrDefault("from", "0")),
                            Long.parseLong(query.getOrDefault("to", Long.toString(Long.MAX_VALUE))),
                            Long.parseLong(query.getOrDefault("beforeId", Long.toString(Long.MAX_VALUE))),
                            Integer.parseInt(query.getOrDefault("limit", "100")), query.getOrDefault(traffic ? "sessionId" : "target", ""));
                }
                case "GET /api/v1/tunnels" -> data = control.tunnels();
                case "POST /api/v1/proxy/start" -> { control.start(); data = control.status(); }
                case "POST /api/v1/proxy/stop" -> { control.stop(); data = control.status(); }
                case "POST /api/v1/proxy/restart" -> { control.restart(); data = control.status(); }
                case "POST /api/v1/kernel/shutdown" -> {
                    return new Response(200, Map.of("requestId", requestId, "data", Map.of("stopping", true)), true);
                }
                case "GET /api/v1/config" -> data = control.configuration();
                case "POST /api/v1/config/validate" -> data = control.validate(body);
                case "PUT /api/v1/config" -> { control.configure(body, revision(ifMatch)); data = control.configuration(); }
                case "GET /api/v1/settings" -> data = control.settings();
                case "PATCH /api/v1/settings" -> { control.patchSettings(body, revision(ifMatch)); data = control.settings(); }
                case "GET /api/v1/profiles" -> data = control.configuration().getAsJsonArray("connections");
                case "POST /api/v1/profiles" -> { String id = control.createProfile(body, revision(ifMatch)); data = control.profile(id); status = 201; }
                case "PUT /api/v1/routing/mode" -> { control.mode(string(body, "mode"), revision(ifMatch)); data = control.routing(); }
                case "POST /api/v1/overview/websites" -> { data = control.networkTest("websites"); status = 202; }
                case "POST /api/v1/overview/exit-ip" -> { data = control.networkTest("exit-ip"); status = 202; }
                case "POST /api/v1/overview/latency" -> { data = control.networkTest("latency"); status = 202; }
                case "GET /api/v1/routing/export" -> data = control.exportRouting();
                case "POST /api/v1/routing/import" -> { control.importRouting(body, revision(ifMatch)); data = control.routing(); }
                case "GET /api/v1/routing" -> data = control.routing();
                case "PUT /api/v1/routing/default" -> { control.select(string(body, "profileId"), revision(ifMatch)); data = control.routing(); }
                case "PUT /api/v1/routing/direct-rules" -> { control.updateRules(string(body, "rules"), revision(ifMatch)); data = control.routing(); }
                case "PUT /api/v1/routing/targets" -> { control.routeTarget(string(body, "target"), string(body, "route"), revision(ifMatch)); data = control.routing(); }
                case "POST /api/v1/routing/validate" -> { KernelControl.validateRules(string(body, "rules")); data = Map.of("valid", true); }
                case "POST /api/v1/routing/resolve" -> { data = control.resolve(string(body, "target")); status = 202; }
                case "GET /api/v1/logs" -> {
                    Map<String, String> query = query(uri);
                    long after = Long.parseLong(query.getOrDefault("after", "0"));
                    int limit = Integer.parseInt(query.getOrDefault("limit", "100"));
                    if (after < 0 || limit < 1 || limit > 500) throw new ControlException(400, "INVALID_QUERY", "日志查询范围无效");
                    data = control.logs().read(after, limit, ControlLogs.parseLevels(query.get("levels")));
                }
                default -> {
                    String[] parts = path.split("/");
                    if (parts.length >= 5 && parts[1].equals("api") && parts[2].equals("v1") && parts[3].equals("profiles")) {
                        String id = parts[4];
                        if (parts.length == 5 && method.equals("GET")) data = control.profile(id);
                        else if (parts.length == 5 && method.equals("PATCH")) { control.patchProfile(id, body, revision(ifMatch)); data = control.profile(id); }
                        else if (parts.length == 5 && method.equals("DELETE")) { control.removeProfile(id, revision(ifMatch)); data = Map.of("removed", id); }
                        else if (parts.length == 6 && parts[5].equals("disconnect") && method.equals("POST")) { control.disconnect(id); data = control.status(); }
                        else if (parts.length == 6 && parts[5].equals("tests") && method.equals("POST")) { data = control.test(id, string(body, "target")); status = 202; }
                        else throw notFound();
                    } else if (parts.length == 5 && parts[1].equals("api") && parts[2].equals("v1") && parts[3].equals("operations")) {
                        if (method.equals("DELETE")) control.tasks().cancel(parts[4]);
                        else if (!method.equals("GET")) throw notFound();
                        data = control.tasks().get(parts[4]);
                    } else throw notFound();
                }
            }
            Map<String, Object> response = new LinkedHashMap<>(control.metadata());
            response.put("requestId", requestId); response.put("data", data);
            return new Response(status, response, false);
        }
    }
    private static ControlException notFound() { return new ControlException(404, "NOT_FOUND", "接口不存在或请求方法不支持"); }
    private static String string(JsonObject body, String name) {
        if (!body.has(name) || !body.get(name).isJsonPrimitive() || !body.get(name).getAsJsonPrimitive().isString())
            throw new ControlException(400, "MISSING_FIELD", "缺少有效的字符串字段", name);
        return body.get(name).getAsString();
    }
    private static long revision(String value) {
        if (value == null) throw new ControlException(428, "REVISION_REQUIRED", "修改配置需要通过 If-Match 提交当前版本号");
        long revision = Long.parseLong(value.replace("\"", ""));
        if (revision < 0) throw new ControlException(400, "INVALID_REVISION", "配置版本号无效");
        return revision;
    }
    private static Map<String, String> query(URI uri) {
        Map<String, String> result = new HashMap<>();
        if (uri.getRawQuery() != null) for (String part : uri.getRawQuery().split("&")) {
            String[] pair = part.split("=", 2);
            result.put(URLDecoder.decode(pair[0], StandardCharsets.UTF_8), pair.length == 2 ? URLDecoder.decode(pair[1], StandardCharsets.UTF_8) : "");
        }
        return result;
    }
}
