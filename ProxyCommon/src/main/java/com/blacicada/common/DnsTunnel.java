package com.blacicada.common;

import io.netty.resolver.dns.DnsServerAddressStreamProvider;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * DNS 隧道使用服务端系统上游；查询名用于选择系统中的分域 DNS，不作为连接目标解析。
 */
public record DnsTunnel(String name, int serverIndex) {
    public static final String HEADER = "x-network-dns";
    public static final Authority TARGET = new Authority("system-dns.invalid", 53);
    public static final int MAX_SERVERS = 4;

    public DnsTunnel {
        if (name == null || name.getBytes(StandardCharsets.UTF_8).length > 253
                || serverIndex < 0 || serverIndex >= MAX_SERVERS)
            throw new IllegalArgumentException("DNS 隧道参数无效");
    }

    /**
     * 编码查询名，允许根域、下划线等合法 DNS 查询名称，避免其被当成 HTTP 主机名。
     */
    public String header() {
        return serverIndex + ":" + Base64.getUrlEncoder().withoutPadding().encodeToString(name.getBytes(StandardCharsets.UTF_8));
    }

    public boolean confirmed(List<? extends CharSequence> values) {
        return values.size() == 1 && header().contentEquals(values.getFirst());
    }

    public static DnsTunnel requested(List<? extends CharSequence> values, Authority target) {
        if (values.isEmpty()) return null;
        if (values.size() != 1 || !TARGET.equals(target)) throw new IllegalArgumentException("DNS 隧道标识无效");
        String value = values.getFirst().toString();
        String[] fields = value.split(":", -1);
        if (fields.length != 2) throw new IllegalArgumentException("DNS 隧道标识无效");
        var request = new DnsTunnel(new String(Base64.getUrlDecoder().decode(fields[1]), StandardCharsets.UTF_8),
                Integer.parseInt(fields[0]));
        if (!request.header().equals(value)) throw new IllegalArgumentException("DNS 隧道标识无效");
        return request;
    }

    public InetSocketAddress upstream(DnsServerAddressStreamProvider servers) {
        var stream = servers.nameServerAddressStream(name);
        var addresses = new ArrayList<InetSocketAddress>();
        for (int i = 0; i < Math.min(stream.size(), MAX_SERVERS); i++) {
            var address = stream.next();
            if (!address.isUnresolved() && !addresses.contains(address)) addresses.add(address);
        }
        if (serverIndex >= addresses.size()) throw new IllegalStateException("服务端没有可用的系统 DNS 上游");
        return addresses.get(serverIndex);
    }
}
