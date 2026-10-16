package com.blacicada.proxy;

import com.blacicada.common.ProxyConfig;
import com.blacicada.common.OutboundNetwork;
import io.netty.channel.EventLoop;
import io.netty.resolver.dns.DnsAddressResolverGroup;

/**
 * 正式转发与独立诊断共用协议选择，避免两处创建逻辑发生偏差。
 */
public final class ProxySessionFactory {
    private ProxySessionFactory() {
    }

    public static ProxySession create(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver) throws Exception {
        return create(loop, config, resolver, OutboundNetwork.DEFAULT);
    }

    public static ProxySession create(EventLoop loop, ProxyConfig config, DnsAddressResolverGroup resolver, OutboundNetwork network) throws Exception {
        return switch (config.get("protocol", "http3")) {
            case "http2" -> new Http2Session(loop, config, resolver, network);
            case "http3" -> new Http3Session(loop, config, resolver, network);
            default -> throw new IllegalArgumentException("不支持的代理通信协议");
        };
    }
}
