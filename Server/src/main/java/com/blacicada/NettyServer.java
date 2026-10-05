package com.blacicada;

import com.blacicada.common.h3.ProxyConfig;
import com.blacicada.h3.Http3ProxyServer;
import java.nio.file.Path;

public class NettyServer {
    public static void main(String[] args) throws Exception {
        var config = ProxyConfig.load(Path.of(args.length == 0 ? "server.properties" : args[0]));
        try (var server = new Http3ProxyServer(config).start()) {
            var shutdown = new Thread(server::close, "proxy-server-shutdown");
            Runtime.getRuntime().addShutdownHook(shutdown);
            System.out.println("HTTP/3 代理服务端已监听 UDP " + server.address());
            server.await();
        }
    }
}
