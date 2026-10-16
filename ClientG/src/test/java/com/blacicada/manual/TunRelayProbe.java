package com.blacicada.manual;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import com.blacicada.proxy.LocalProxyServer;
import com.google.gson.Gson;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.management.ManagementFactory;
import java.net.NetworkInterface;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/**
 * 供 ACK 测量脚本启动真实代理；KQueue 仅绑定 lo0，不创建 TUN 或修改系统路由。
 */
public final class TunRelayProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !List.of("kqueue", "nio").contains(args[0]))
            throw new IllegalArgumentException("测量传输必须为 kqueue 或 nio");
        int index = args[0].equals("kqueue") ? NetworkInterface.getByName("lo0").getIndex() : 0;
        Properties values = new Properties();
        values.setProperty("bind", "127.0.0.1");
        values.setProperty("port", "0");
        values.setProperty("routingMode", "direct");
        var config = new KernelConfig(new ProxyConfig(values, Path.of(".")), List.of(), "");
        var operatingSystem = (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
        var json = new Gson();
        try (var proxy = new LocalProxyServer(config, null, null, index).start();
             var input = new BufferedReader(new InputStreamReader(System.in))) {
            do {
                proxy.traffic().sample();
                long active = proxy.tunnels().stream().filter(t -> t.get("state").equals("active")).count();
                System.out.println("测量快照：" + json.toJson(Map.of(
                        "address", "127.0.0.1:" + proxy.address().getPort(), "transport", args[0],
                        "cpuNanos", operatingSystem.getProcessCpuTime(), "activeTunnels", active,
                        "sentBytes", proxy.traffic().snapshot().get("sentBytes"))));
            } while (input.readLine() != null);
        }
    }
}
