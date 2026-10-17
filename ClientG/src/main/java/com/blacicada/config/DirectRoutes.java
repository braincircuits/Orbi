package com.blacicada.config;

import com.blacicada.common.ProxyConfig;
import io.netty.util.NetUtil;

import java.io.IOException;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.Map;
import java.util.TreeMap;

/**
 * 不可变路由规则：精确目标覆盖，以及域名后缀、IP 地址和 CIDR 直连规则。
 */
public final class DirectRoutes {
    private final String text;
    private String mode = "rules";
    private final Set<String> domains;
    private final Set<Network> networks;
    private final Map<String, String> overrides;

    public DirectRoutes(String text) throws IOException {
        this(text, "直连规则", "");
    }

    /**
     * 规则仅来自当前配置快照，外部文件不参与路由。
     */
    public static DirectRoutes load(ProxyConfig config) throws IOException {
        DirectRoutes rules = new DirectRoutes(config.values().getProperty("routesInline", ""), "直连规则",
                config.get("routesOverrides", ""));
        rules.mode = config.get("routingMode", "rules");
        if (!Set.of("rules", "direct", "proxy").contains(rules.mode))
            throw new IllegalArgumentException("全局模式必须为 rules、direct 或 proxy");
        return rules;
    }

    public String mode() {
        return mode;
    }

    public String text() {
        return text;
    }

    public Map<String, String> overrides() {
        return overrides;
    }

    public String override(String host) {
        return overrides.get(hostKey(host));
    }

    /**
     * 精确目标规则优先于域名后缀和 DNS 网段规则；不扩展到子域名。
     */
    public static String normalizeHost(String host) {
        InetAddress address = literal(host);
        if (address != null) return address.getHostAddress();
        String domain = hostKey(host);
        if (domain.length() > 253 || domain.matches("[0-9.]+")
                || !domain.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*"))
            throw new IllegalArgumentException("应填写有效的域名或 IP 地址");
        return domain;
    }

    private static String hostKey(String host) {
        InetAddress address = literal(host);
        return address != null ? address.getHostAddress() : java.net.IDN.toASCII(normalize(host));
    }

    /**
     * 忽略注释、顺序、重复项及 CIDR 主机位，避免无效编辑触发重复 DNS。
     */
    public boolean sameRules(DirectRoutes other) {
        return mode.equals(other.mode) && domains.equals(other.domains) && networks.equals(other.networks) && overrides.equals(other.overrides);
    }

    private DirectRoutes(String text, String source, String overrideText) throws IOException {
        this.text = text;
        var domainRules = new HashSet<String>();
        var networkRules = new ArrayList<Network>();
        {
            int lineNumber = 0;
            for (String line : text.lines().toList()) {
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
                        if (address != null)
                            networkRules.add(new Network(address.getAddress(), address.getAddress().length * 8));
                        else {
                            domainRules.add(normalizeHost(rule));
                        }
                    }
                } catch (IllegalArgumentException e) {
                    throw new IOException("直连规则无效，位置：" + source + ":" + lineNumber + ": 请填写有效域名、IP 或 CIDR 网段");
                }
            }
        }
        domains = Set.copyOf(domainRules);
        networks = Set.copyOf(networkRules);
        var targetRules = new TreeMap<String, String>();
        int lineNumber = 0;
        for (String line : overrideText.lines().toList()) {
            lineNumber++;
            if (line.isBlank()) continue;
            String[] fields = line.trim().split("\\s+", 2);
            try {
                if (fields.length != 2 || !Set.of("proxy", "direct").contains(fields[0]))
                    throw new IllegalArgumentException("目标规则应为 proxy/direct 域名或IP");
                targetRules.put(normalizeHost(fields[1]), fields[0]);
            } catch (IllegalArgumentException e) {
                throw new IOException("目标路由规则无效，位置：routesOverrides:" + lineNumber);
            }
        }
        overrides = Map.copyOf(targetRules);
    }

    /**
     * 合并规则原文并保留备注；相同规则优先保留现有行，CIDR 忽略主机位。
     */
    public static String mergeText(String current, String incoming) throws IOException {
        new DirectRoutes(current);
        new DirectRoutes(incoming);
        var keys = new HashSet<Object>();
        var lines = new ArrayList<String>();
        for (String line : (current + "\n" + incoming).split("\n", -1)) {
            String rule = line.split("#", 2)[0].trim();
            if (rule.isEmpty()) {
                lines.add(line);
                continue;
            }
            int slash = rule.indexOf('/');
            var address = literal(slash < 0 ? rule : rule.substring(0, slash));
            Object key = address == null ? normalizeHost(rule) : new Network(address.getAddress(),
                    slash < 0 ? address.getAddress().length * 8 : Integer.parseInt(rule.substring(slash + 1)));
            if (keys.add(key)) lines.add(line);
        }
        return String.join("\n", lines).strip();
    }

    /**
     * 不执行 DNS 解析；IP 地址不参与域名后缀匹配。
     */
    public boolean matches(String host) {
        if (!mode.equals("rules")) return mode.equals("direct");
        String override = override(host);
        if (override != null) return override.equals("direct");
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
        if (!mode.equals("rules")) return mode.equals("direct");
        byte[] bytes = address.getAddress();
        return networks.stream().anyMatch(network -> network.matches(bytes));
    }

    public boolean needsResolution(String host) {
        return mode.equals("rules") && override(host) == null && !networks.isEmpty() && literal(host) == null;
    }

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
            address = address.clone();
            for (int bit = prefix; bit < address.length * 8; bit++) address[bit / 8] &= (byte) ~(1 << (7 - bit % 8));
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Network network && prefix == network.prefix && Arrays.equals(address, network.address);
        }

        @Override
        public int hashCode() {
            return 31 * Arrays.hashCode(address) + prefix;
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
