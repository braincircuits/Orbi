package com.blacicada;

import com.blacicada.common.h3.ProxyConfig;
import com.blacicada.h3.LocalProxyServer;
import java.nio.file.Path;

public class ClientApplication {
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("--ui")) {
            // 控制协议独占原始标准输出，普通输出及日志进入标准错误。
            var protocol = System.out;
            System.setOut(System.err);
            com.blacicada.control.UiControl.run(System.in, protocol);
            return;
        }
        var config = com.blacicada.config.KernelConfig.load(Path.of(args.length == 0 ? "client.properties" : args[0]));
        try (var proxy = new LocalProxyServer(config).start()) {
            Runtime.getRuntime().addShutdownHook(new Thread(proxy::close, "proxy-client-shutdown"));
            System.out.println("本地 HTTP 代理已监听 " + proxy.address());
            proxy.await();
        }
    }
}
