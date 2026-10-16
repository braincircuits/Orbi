package com.blacicada;

import com.blacicada.common.ProxyConfig;
import com.blacicada.h3.Http3ProxyServer;
import com.blacicada.h2.Http2ProxyServer;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.util.*;

public class NettyServer {
    public static void main(String[] args) throws Exception {
        logBuildIdentity();
        var config = ProxyConfig.load(Path.of(args.length == 0 ? "server.properties" : args[0]));
        System.out.println("服务端每连接并发流上限：" + config.maxStreams());
        Set<String> protocols = new HashSet<>(Arrays.stream(config.get("protocols", "http3").split(",", -1)).map(String::trim).toList());
        if (protocols.isEmpty() || !Set.of("http2", "http3").containsAll(protocols))
            throw new IllegalArgumentException("protocols 仅支持 http2、http3，以逗号分隔");
        try (var h3 = protocols.contains("http3") ? new Http3ProxyServer(config) : null;
             var h2 = protocols.contains("http2") ? new Http2ProxyServer(config) : null) {
            var shutdown = new Thread(() -> {
                if (h3 != null) h3.close();
                if (h2 != null) h2.close();
            }, "proxy-server-shutdown");
            Runtime.getRuntime().addShutdownHook(shutdown);
            try {
                if (h3 != null) {
                    h3.start();
                    System.out.println("HTTP/3 代理服务端已监听 UDP " + h3.address());
                }
                if (h2 != null) {
                    h2.start();
                    System.out.println("HTTP/2 代理服务端已监听 TCP " + h2.address());
                }
                if (h3 != null) h3.await();
                else h2.await();
            } finally {
                try {
                    Runtime.getRuntime().removeShutdownHook(shutdown);
                } catch (IllegalStateException ignored) {
                }
            }
        }
    }

    private static void logBuildIdentity() {
        System.out.println("服务端协议支持：HTTP/2、HTTP/3 CONNECT；UDP 标识=x-network-transport: udp；报文封装=2 字节长度＋报文");
        try {
            var source = NettyServer.class.getProtectionDomain().getCodeSource();
            if (source == null) {
                System.out.println("服务端构建标识不可用：无法定位程序来源");
                return;
            }
            Path artifact = Path.of(source.getLocation().toURI()).toRealPath();
            System.out.println("服务端程序路径：" + artifact);
            if (!Files.isRegularFile(artifact)) {
                System.out.println("服务端构建标识不可用：当前从开发目录启动，未加载 JAR");
                return;
            }
            // 对实际加载的 JAR 计算摘要，同一文件重启后标识不变，可与部署文件直接核对。
            var digest = MessageDigest.getInstance("SHA-256");
            try (var input = new DigestInputStream(Files.newInputStream(artifact), digest)) {
                input.transferTo(OutputStream.nullOutputStream());
            }
            System.out.println("服务端构建标识（JAR SHA-256）：" + HexFormat.of().formatHex(digest.digest()));
        } catch (Exception e) {
            System.err.println("读取服务端构建标识失败：" + e);
        }
    }
}
