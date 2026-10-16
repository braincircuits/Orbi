package com.blacicada.common;

import java.net.IDN;
import java.net.InetSocketAddress;
import java.util.Locale;

import io.netty.util.NetUtil;

/**
 * 解析 host:port，支持方括号包裹的 IPv6；不执行 DNS 解析。
 */
public record Authority(String host, int port) {
    public Authority {
        if (host == null || host.isBlank() || port < 1 || port > 65535) {
            throw new IllegalArgumentException("目标地址无效");
        }
        if (host.indexOf(':') >= 0) {
            if (!NetUtil.isValidIpV6Address(host)) throw new IllegalArgumentException("IPv6 地址无效");
        } else {
            host = IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
        }
    }

    public static Authority parse(String authority, int defaultPort) {
        if (authority == null || authority.isBlank() || !authority.equals(authority.trim())) {
            throw new IllegalArgumentException("地址缺失或无效");
        }
        if (authority.startsWith("[")) {
            int end = authority.indexOf(']');
            if (end < 0) throw new IllegalArgumentException("IPv6 地址格式无效");
            String rest = authority.substring(end + 1);
            if (!rest.isEmpty() && !rest.startsWith(":")) throw new IllegalArgumentException("地址格式无效");
            return new Authority(authority.substring(1, end), rest.isEmpty() ? defaultPort : port(rest.substring(1)));
        }
        int colon = authority.lastIndexOf(':');
        if (colon != authority.indexOf(':')) throw new IllegalArgumentException("IPv6 地址必须用方括号包裹");
        return colon < 0 ? new Authority(authority, defaultPort)
                : new Authority(authority.substring(0, colon), port(authority.substring(colon + 1)));
    }

    private static int port(String value) {
        if (value.isEmpty() || !value.chars().allMatch(c -> c >= '0' && c <= '9')) {
            throw new IllegalArgumentException("目标端口无效");
        }
        return Integer.parseInt(value);
    }

    public InetSocketAddress unresolved() {
        return InetSocketAddress.createUnresolved(host, port);
    }

    @Override
    public String toString() {
        return (host.indexOf(':') >= 0 ? "[" + host + "]" : host) + ":" + port;
    }
}
