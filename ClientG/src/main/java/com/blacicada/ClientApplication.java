package com.blacicada;

import com.blacicada.common.h3.ProxyConfig;
import com.blacicada.h3.LocalProxyServer;
import java.nio.file.Path;

public class ClientApplication {
    public static void main(String[] args) throws Exception {
        var config = ProxyConfig.load(Path.of(args.length == 0 ? "client.properties" : args[0]));
        try (var proxy = new LocalProxyServer(config).start()) {
            Runtime.getRuntime().addShutdownHook(new Thread(proxy::close, "proxy-client-shutdown"));
            System.out.println("Local HTTP proxy listening on " + proxy.address());
            proxy.await();
        }
    }
}
