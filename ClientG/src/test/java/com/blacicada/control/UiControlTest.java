package com.blacicada.control;

import com.google.gson.*;
import org.junit.jupiter.api.Test;
import java.io.*;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class UiControlTest {
    private List<JsonObject> exchange(String... commands) throws Exception {
        var output = new ByteArrayOutputStream();
        UiControl.run(new ByteArrayInputStream(String.join("\n", commands).getBytes(StandardCharsets.UTF_8)),
                new PrintStream(output, true, StandardCharsets.UTF_8));
        return output.toString(StandardCharsets.UTF_8).lines().map(s -> JsonParser.parseString(s).getAsJsonObject()).toList();
    }

    private String start(int port) {
        return "{\"id\":\"start\",\"command\":\"start\",\"config\":{\"server.host\":\"127.0.0.1\",\"server.port\":\"4433\",\"port\":\""
                + port + "\",\"password\":\"test-secret\"},\"rules\":\"\"}";
    }

    private JsonObject response(List<JsonObject> events, String id) {
        return events.stream().filter(e -> e.has("id") && e.get("id").getAsString().equals(id)).findFirst().orElseThrow();
    }

    @Test void startsStopsAndClosesListenerOnInputEnd() throws Exception {
        int port;
        try (var socket = new ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))) { port = socket.getLocalPort(); }
        var events = exchange(start(port), "{\"id\":\"status\",\"command\":\"status\"}");
        assertTrue(response(events, "start").get("ok").getAsBoolean());
        var status = response(events, "status").getAsJsonObject("status");
        assertTrue(status.get("running").getAsBoolean());
        assertEquals("idle", status.get("connection").getAsString());
        assertFalse(events.toString().contains("test-secret"));
        try (var socket = new ServerSocket(port)) { assertTrue(socket.isBound()); }
    }

    @Test void reportsPortConflictAndRemainsControllable() throws Exception {
        try (var socket = new ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))) {
            var events = exchange(start(socket.getLocalPort()), "{\"id\":\"stop\",\"command\":\"stop\"}");
            assertFalse(response(events, "start").get("ok").getAsBoolean());
            assertTrue(response(events, "stop").get("ok").getAsBoolean());
            assertFalse(response(events, "stop").getAsJsonObject("status").get("running").getAsBoolean());
        }
    }

    @Test void rejectsMalformedRulesWithoutStartingProxy() throws Exception {
        for (String rule : List.of("10.0.0.0/33", "https://example.com", "*.example.com", "192.168.*.*")) {
            var events = exchange("{\"id\":\"validate\",\"command\":\"validate\",\"rules\":\"" + rule + "\"}");
            assertFalse(response(events, "validate").get("ok").getAsBoolean(), rule);
        }
    }

    @Test void acceptsRulesAndRecoversAfterInvalidJson() throws Exception {
        var events = exchange("not-json", "{\"id\":\"valid\",\"command\":\"validate\",\"rules\":\"example.com\\n::1/128\\n10.0.0.0/8\"}");
        assertTrue(response(events, "valid").get("ok").getAsBoolean());
        assertEquals("ready", events.getFirst().get("event").getAsString());
    }

    @Test void managesMultipleProfilesAndPersistsWithoutExposingPasswords() throws Exception {
        var file = java.nio.file.Files.createTempFile("network-config-test-", ".json");
        try {
            JsonObject configuration = new JsonObject(); configuration.addProperty("version", 1);
            configuration.addProperty("defaultConnectionId", "h3");
            configuration.add("local", JsonParser.parseString("{\"port\":0,\"routesInline\":\"10.0.0.0/8\"}"));
            configuration.add("connections", JsonParser.parseString("[{\"id\":\"h3\",\"name\":\"节点三\",\"config\":{\"protocol\":\"http3\",\"server.host\":\"localhost\",\"password\":\"hidden-value\"}},{\"id\":\"h2\",\"name\":\"节点二\",\"config\":{\"protocol\":\"http2\",\"server.host\":\"localhost\",\"password\":\"hidden-value\"}}]"));
            JsonObject configure = new JsonObject(); configure.addProperty("id", "configure"); configure.addProperty("command", "configure"); configure.add("configuration", configuration);
            JsonObject save = new JsonObject(); save.addProperty("id", "save"); save.addProperty("command", "config.save"); save.addProperty("path", file.toString());
            var events = exchange(configure.toString(), "{\"id\":\"start\",\"command\":\"start\"}",
                    "{\"id\":\"select\",\"command\":\"connection.select\",\"connectionId\":\"h2\"}",
                    "{\"id\":\"remove\",\"command\":\"connection.remove\",\"connectionId\":\"h3\"}",
                    "{\"id\":\"get\",\"command\":\"config.get\"}", save.toString());
            for (String id : List.of("configure", "start", "select", "remove", "get", "save")) assertTrue(response(events, id).get("ok").getAsBoolean(), id);
            assertFalse(events.toString().contains("hidden-value"));
            var loaded = com.blacicada.config.KernelConfig.load(file);
            assertEquals("h2", loaded.defaultConnectionId()); assertEquals(1, loaded.connections().size());
            assertEquals("10.0.0.0/8", loaded.local().get("routesInline", ""));
        } finally { java.nio.file.Files.deleteIfExists(file); }
    }
}
