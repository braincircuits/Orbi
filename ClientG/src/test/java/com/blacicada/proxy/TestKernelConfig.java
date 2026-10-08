package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.config.KernelConfig;
import java.util.*;

/** 测试夹具分别组织公共参数和单个测试节点的参数。 */
final class TestKernelConfig {
    static KernelConfig from(ProxyConfig options) {
        Properties local = new Properties(), connection = options.values();
        for (String key : List.of("bind", "port", "routesFile", "routesInline")) {
            Object value = connection.remove(key);
            if (value != null) local.put(key, value);
        }
        local.setProperty("connectTimeoutMillis", "" + options.connectTimeoutMillis());
        return new KernelConfig(new ProxyConfig(local, options.base()), List.of(
                new KernelConfig.Profile("test", "测试节点", new ProxyConfig(connection, options.base()))), "test");
    }
}
