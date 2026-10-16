package com.blacicada.control;

import com.google.gson.*;
import io.netty.util.NetUtil;

import java.io.IOException;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * 从实际本地入口发起有界请求，遵循当前路由且不使用系统代理。
 */
final class NetworkProbe {
    static final Map<String, URI> WEBSITES = Collections.unmodifiableMap(new LinkedHashMap<>(Map.of(
            "github", URI.create("https://github.com/"),
            "google", URI.create("https://www.google.com/"),
            "youtube", URI.create("https://www.youtube.com/"))));
    static final URI IP_SERVICE = URI.create("https://ipwho.is/?fields=success,ip,type,country,region,city,connection&lang=zh-CN");

    private NetworkProbe() {
    }

    static HttpResponse<byte[]> request(InetSocketAddress proxy, URI uri, boolean body) throws Exception {
        HttpClient client = HttpClient.newBuilder().proxy(ProxySelector.of(proxy))
                .connectTimeout(Duration.ofSeconds(5)).followRedirects(HttpClient.Redirect.NEVER)
                .version(HttpClient.Version.HTTP_1_1).build();
        CompletableFuture<HttpResponse<byte[]>> pending = null;
        try {
            var request = HttpRequest.newBuilder(uri).timeout(Duration.ofSeconds(5))
                    .header("User-Agent", "Network/1.0").method(body ? "GET" : "HEAD", HttpRequest.BodyPublishers.noBody()).build();
            pending = client.sendAsync(request, HttpResponse.BodyHandlers.limiting(HttpResponse.BodyHandlers.ofByteArray(), 65_536));
            return pending.get(5, TimeUnit.SECONDS);
        } finally {
            if (pending != null) pending.cancel(true);
            client.shutdownNow();
        }
    }

    static Map<String, Object> website(InetSocketAddress proxy, String id, URI uri) throws InterruptedException {
        long started = System.nanoTime();
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", id);
        result.put("url", uri.toString());
        result.put("checkedAt", Instant.now().toString());
        try {
            var response = request(proxy, uri, false);
            result.put("latencyMillis", (System.nanoTime() - started) / 1_000_000.0);
            result.put("httpStatus", response.statusCode());
            result.put("state", response.statusCode() >= 200 && response.statusCode() < 400 ? "reachable" : "http_error");
        } catch (InterruptedException e) {
            throw e;
        } catch (Exception e) {
            Throwable cause = e;
            while (cause.getCause() != null && cause != cause.getCause()) cause = cause.getCause();
            result.put("state", cause instanceof TimeoutException || cause instanceof HttpTimeoutException ? "timeout" : "failed");
            result.put("message", "请求未完成，请检查当前模式和网络连接");
        }
        return Map.copyOf(result);
    }

    static Map<String, Object> exitIp(InetSocketAddress proxy) throws Exception {
        var response = request(proxy, IP_SERVICE, true);
        if (response.statusCode() != 200) throw new IOException("出口 IP 查询服务返回异常状态");
        return parseIp(new String(response.body(), StandardCharsets.UTF_8));
    }

    static Map<String, Object> parseIp(String json) throws IOException {
        try {
            JsonObject value = JsonParser.parseString(json).getAsJsonObject();
            String ip = text(value, "ip");
            if (!value.has("success") || !value.get("success").getAsBoolean()
                    || !(NetUtil.isValidIpV4Address(ip) || NetUtil.isValidIpV6Address(ip)))
                throw new IOException("出口 IP 查询结果无效");
            JsonObject network = value.has("connection") && value.get("connection").isJsonObject()
                    ? value.getAsJsonObject("connection") : new JsonObject();
            return Map.of("ip", ip, "country", text(value, "country"), "region", text(value, "region"),
                    "city", text(value, "city"), "provider", text(network, "isp"), "source", "ipwho.is",
                    "checkedAt", Instant.now().toString());
        } catch (RuntimeException e) {
            throw new IOException("出口 IP 查询响应格式无效", e);
        }
    }

    private static String text(JsonObject object, String key) {
        return object.has(key) && !object.get(key).isJsonNull() ? object.get(key).getAsString() : "";
    }
}
