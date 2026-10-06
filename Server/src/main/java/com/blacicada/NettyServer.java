package com.blacicada;

import com.blacicada.common.h3.ProxyConfig;
import com.blacicada.h3.Http3ProxyServer;
import com.blacicada.h2.Http2ProxyServer;
import java.nio.file.Path;
import java.util.*;

public class NettyServer {
    public static void main(String[] args) throws Exception {
        var config = ProxyConfig.load(Path.of(args.length == 0 ? "server.properties" : args[0]));
        Set<String> protocols = new HashSet<>(Arrays.stream(config.get("protocols", "http3").split(",", -1)).map(String::trim).toList());
        if (protocols.isEmpty() || !Set.of("http2", "http3").containsAll(protocols))
            throw new IllegalArgumentException("protocols 仅支持 http2、http3，以逗号分隔");
        try (var h3 = protocols.contains("http3") ? new Http3ProxyServer(config) : null;
             var h2 = protocols.contains("http2") ? new Http2ProxyServer(config) : null) {
            var shutdown = new Thread(() -> { if (h3 != null) h3.close(); if (h2 != null) h2.close(); }, "proxy-server-shutdown");
            Runtime.getRuntime().addShutdownHook(shutdown);
            try {
                if (h3 != null) { h3.start(); System.out.println("HTTP/3 代理服务端已监听 UDP " + h3.address()); }
                if (h2 != null) { h2.start(); System.out.println("HTTP/2 代理服务端已监听 TCP " + h2.address()); }
                if (h3 != null) h3.await(); else h2.await();
            } finally { try { Runtime.getRuntime().removeShutdownHook(shutdown); } catch (IllegalStateException ignored) { } }
        }
    }
}
