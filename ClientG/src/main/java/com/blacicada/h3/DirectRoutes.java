package com.blacicada.h3;

import io.netty.util.NetUtil;
import java.io.IOException;
import java.net.InetAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** 不可变的直连规则：域名后缀、IP 地址和 CIDR 网段。 */
public final class DirectRoutes {
    private final Set<String> domains;
    private final List<Network> networks;

    public DirectRoutes(Path file) throws IOException {
        this(Files.exists(file) ? Files.readAllLines(file) : List.of(), file.toString());
    }

    public DirectRoutes(String text) throws IOException { this(text.lines().toList(), "控制接口"); }

    private DirectRoutes(List<String> lines, String source) throws IOException {
        var domainRules = new HashSet<String>();
        var networkRules = new ArrayList<Network>();
        {
            int lineNumber = 0;
            for (String line : lines) {
                lineNumber++;
                String rule = line.split("#", 2)[0].trim();
                if (rule.isEmpty()) continue;
                try {
                    int slash = rule.indexOf('/');
                    if (slash >= 0) {
                        InetAddress address = literal(rule.substring(0, slash));
                        String prefix = rule.substring(slash + 1);
                        if (address == null || !prefix.matches("[0-9]+")) {
                            throw new IllegalArgumentException("应使用 IP/前缀长度 格式");
                        }
                        networkRules.add(new Network(address.getAddress(), Integer.parseInt(prefix)));
                    } else {
                        InetAddress address = literal(rule);
                        if (address != null) networkRules.add(new Network(address.getAddress(), address.getAddress().length * 8));
                        else {
                            String domain = java.net.IDN.toASCII(normalize(rule));
                            if (domain.length() > 253 || domain.matches("[0-9.]+")
                                    || !domain.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*"))
                                throw new IllegalArgumentException("应填写域名、IP 或 CIDR，不支持 URL 和通配符");
                            domainRules.add(domain);
                        }
                    }
                } catch (IllegalArgumentException e) {
                    throw new IOException("直连规则无效，位置：" + source + ":" + lineNumber + ": " + rule, e);
                }
            }
        }
        domains = Set.copyOf(domainRules);
        networks = List.copyOf(networkRules);
    }

    /** 不执行 DNS 解析；IP 地址不参与域名后缀匹配。 */
    public boolean matches(String host) {
        InetAddress address = literal(host);
        if (address != null) return matches(address);
        String name = normalize(host);
        while (true) {
            if (domains.contains(name)) return true;
            int dot = name.indexOf('.');
            if (dot < 0) return false;
            name = name.substring(dot + 1);
        }
    }

    public boolean matches(InetAddress address) {
        byte[] bytes = address.getAddress();
        return networks.stream().anyMatch(network -> network.matches(bytes));
    }

    public boolean needsResolution(String host) { return !networks.isEmpty() && literal(host) == null; }

    private static InetAddress literal(String host) {
        return NetUtil.isValidIpV4Address(host) || NetUtil.isValidIpV6Address(host)
                ? InetAddress.ofLiteral(host) : null;
    }

    private static String normalize(String name) {
        name = name.toLowerCase(Locale.ROOT);
        return name.endsWith(".") ? name.substring(0, name.length() - 1) : name;
    }

    private record Network(byte[] address, int prefix) {
        Network {
            if (prefix < 0 || prefix > address.length * 8) throw new IllegalArgumentException("网段前缀长度无效");
        }
        boolean matches(byte[] candidate) {
            if (candidate.length != address.length) return false;
            int fullBytes = prefix / 8;
            for (int i = 0; i < fullBytes; i++) if (candidate[i] != address[i]) return false;
            int remaining = prefix % 8;
            int mask = (0xff << (8 - remaining)) & 0xff;
            return remaining == 0 || (candidate[fullBytes] & mask) == (address[fullBytes] & mask);
        }
    }
}
