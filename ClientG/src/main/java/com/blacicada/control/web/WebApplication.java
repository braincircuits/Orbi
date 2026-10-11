package com.blacicada.control.web;

import com.blacicada.control.KernelControl;
import java.nio.file.*;
import java.util.*;

/** 管理地址、令牌和跨域白名单是启动参数，不随代理配置热更新。 */
public final class WebApplication {
    private WebApplication() { }
    /** 原生程序取进程映像位置，JAR 取代码来源；IDE 运行时使用编译输出目录。 */
    static Path defaultDatabase() throws Exception {
        if ("runtime".equals(System.getProperty("org.graalvm.nativeimage.imagecode"))) {
            Path executable = Path.of(ProcessHandle.current().info().command()
                    .orElseThrow(() -> new IllegalStateException("无法确定可执行程序路径，请使用 --db 指定数据库"))).toRealPath();
            return executable.getParent().resolve("kernel.db");
        }
        Path source = Path.of(WebApplication.class.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath();
        return (Files.isDirectory(source) ? source : source.getParent()).resolve("kernel.db");
    }
    public static void run(String[] args) throws Exception {
        Path database = null, endpoint = null;
        int port = 9090;
        Set<String> origins = new HashSet<>();
        String token = ControlHttpServer.newToken();
        for (int i = 0; i < args.length; i++) {
            String key = args[i];
            if (i + 1 >= args.length) throw new IllegalArgumentException("启动参数缺少值：" + key);
            String value = args[++i];
            switch (key) {
                case "--db" -> database = Path.of(value);
                case "--port" -> port = Integer.parseInt(value);
                case "--endpoint-file" -> endpoint = Path.of(value);
                case "--token-file" -> token = Files.readString(Path.of(value)).trim();
                case "--allow-origin" -> {
                    java.net.URI uri = java.net.URI.create(value);
                    if (!Set.of("http", "https").contains(uri.getScheme()) || uri.getHost() == null
                            || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null
                            || !uri.getRawPath().isEmpty()) throw new IllegalArgumentException("允许来源必须是完整的 HTTP 或 HTTPS Origin");
                    origins.add(value);
                }
                default -> throw new IllegalArgumentException("未知启动参数：" + key);
            }
        }
        if (port < 0 || port > 65535) throw new IllegalArgumentException("管理端口无效");
        if (database == null) database = defaultDatabase();
        if (endpoint == null) endpoint = database.toAbsolutePath().getParent().resolve("run/control.json");
        Path endpointFile = endpoint.toAbsolutePath();
        try (var control = new KernelControl(database); var web = new ControlHttpServer(control, port, token, origins)) {
            var hook = new Thread(web::close, "web-control-shutdown");
            Runtime.getRuntime().addShutdownHook(hook);
            try {
                web.start(); web.writeEndpoint(endpointFile);
                System.out.println("代理内核管理接口已启动：" + web.url());
                System.out.println("管理连接信息文件：" + endpointFile);
                // 管理接口启动后保持代理停止，代理客户端按需要显式启动转发。
                web.await();
            } finally {
                try { Runtime.getRuntime().removeShutdownHook(hook); } catch (IllegalStateException ignored) { }
                // 只删除本进程创建的发现文件，避免覆盖其他实例的状态。
                if (Files.exists(endpointFile)) {
                    var value = com.google.gson.JsonParser.parseString(Files.readString(endpointFile)).getAsJsonObject();
                    if (value.get("pid").getAsLong() == ProcessHandle.current().pid()) Files.deleteIfExists(endpointFile);
                }
            }
        }
    }
}
