package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.Transport;
import com.blacicada.config.DirectRoutes;
import com.blacicada.config.KernelConfig;
import io.netty.channel.Channel;
import io.netty.resolver.AddressResolver;
import io.netty.util.AttributeKey;
import io.netty.util.concurrent.Future;
import org.apache.logging.log4j.LogManager;

import java.net.InetSocketAddress;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * 每条浏览器连接自己的路由状态；所有访问都在该连接的 EventLoop 中执行。
 */
final class LocalSession {
    static final AttributeKey<LocalSession> KEY = AttributeKey.valueOf(LocalSession.class, "session");
    private final Channel browser;
    private final Authority target;
    private final Authority displayTarget;
    private final InetSocketAddress originalAddress;
    private final long createdAt = System.currentTimeMillis();
    private final AddressResolver<InetSocketAddress> resolver;
    private Consumer<InetSocketAddress> start;
    private DirectRoutes rules;
    private Boolean direct;
    private List<InetSocketAddress> addresses;
    private InetSocketAddress directAddress;
    private Future<List<InetSocketAddress>> lookup;
    private Channel remote;
    private boolean closed;
    private boolean udp;

    void udp(boolean value) {
        udp = value;
    }

    /**
     * 首次决定路由时回调一次；地址为 null 表示走代理。
     */
    LocalSession(Channel browser, Authority target, AddressResolver<InetSocketAddress> resolver,
                 Consumer<InetSocketAddress> start) {
        this(browser, target, null, resolver, start);
    }

    LocalSession(Channel browser, Authority target, String associatedDomain, AddressResolver<InetSocketAddress> resolver,
                 Consumer<InetSocketAddress> start) {
        this.browser = browser;
        this.target = target;
        this.resolver = resolver;
        this.start = start;
        displayTarget = associatedDomain == null ? target : new Authority(associatedDomain, target.port());
        originalAddress = associatedDomain == null ? null
                : new InetSocketAddress(java.net.InetAddress.ofLiteral(target.host()), target.port());
        browser.attr(KEY).set(this);
        browser.closeFuture().addListener(ignored -> {
            closed = true;
            this.start = null;
            cancelLookup();
            browser.attr(KEY).set(null);
        });
    }

    void apply(DirectRoutes next) {
        if (closed || rules != null && rules.sameRules(next)) return;
        rules = next;
        evaluate();
    }

    boolean isClosed() {
        return closed;
    }

    /**
     * 在所属 EventLoop 中读取不可变快照，不暴露 Channel 或凭据。
     */
    Map<String, Object> snapshot(KernelConfig config) {
        var profile = direct == null || direct ? null : config.profile(config.defaultConnectionId());
        var source = browser.remoteAddress();
        String sourceText = source instanceof InetSocketAddress address
                ? (address.getHostString().contains(":") ? "[" + address.getHostString() + "]" : address.getHostString()) + ":" + address.getPort()
                : String.valueOf(source);
        return Map.of("id", browser.id().asLongText(), "target", displayTarget.toString(), "source", sourceText,
                "route", direct == null ? "resolving" : direct ? "direct" : "proxy",
                "state", direct == null ? "resolving" : remote != null && remote.isActive() ? "active" : "pending",
                "profileId", profile == null ? "" : profile.id(), "profileName", profile == null ? "" : profile.name(),
                "originalProtocol", udp ? "udp" : "tcp",
                "protocol", profile == null ? (udp ? "udp" : "tcp") : profile.config().get("protocol", "http3"), "createdAt", createdAt);
    }

    /**
     * 记录实际连接地址，防止 DNS 多地址中另一个地址命中规则却保留错误的直连。
     */
    boolean remote(Channel channel) {
        remote = channel;
        if (closed || !browser.isActive()) {
            Transport.abort(channel);
            return false;
        }
        if (Boolean.TRUE.equals(direct) && channel.remoteAddress() instanceof InetSocketAddress address && !address.isUnresolved()) {
            directAddress = address;
            evaluate();
        }
        return !closed;
    }

    private void evaluate() {
        if (closed || !browser.isActive()) return;
        if (originalAddress != null) {
            // 关联仅影响展示与规则；实际出站始终保留应用选择的原始 IP。
            // 全局模式优先，其次是原始 IP 精确规则、关联域名精确规则、域名后缀和 IP 网段。
            decide(associatedTargetUsesDirectRoute() ? originalAddress : null);
        } else if (rules.matches(target.host())) {
            cancelLookup();
            decide(target.unresolved());
        } else if (!rules.needsResolution(target.host())) {
            cancelLookup();
            decide(null);
        } else if (directAddress != null) {
            cancelLookup();
            decide(rules.matches(directAddress.getAddress()) ? directAddress : null);
        } else if (addresses != null) {
            decide(addresses.stream().filter(address -> rules.matches(address.getAddress())).findFirst().orElse(null));
        } else if (lookup == null) {
            var request = resolver.resolveAll(target.unresolved());
            lookup = request;
            request.addListener(done -> {
                if (closed || lookup != request) return;
                lookup = null;
                // 只保存地址；回调始终按最新规则判断，不沿用发起 DNS 时的规则。
                addresses = done.isSuccess() ? List.copyOf(request.getNow()) : List.of();
                evaluate();
            });
        }
    }

    private boolean associatedTargetUsesDirectRoute() {
        if (!rules.mode().equals("rules")) return rules.mode().equals("direct");
        if (rules.override(target.host()) != null) return rules.matches(target.host());
        if (rules.override(displayTarget.host()) != null) return rules.matches(displayTarget.host());
        return rules.matches(displayTarget.host()) || rules.matches(target.host());
    }

    private void decide(InetSocketAddress address) {
        boolean nextDirect = address != null;
        if (direct == null) {
            direct = nextDirect;
            if (nextDirect && !address.isUnresolved()) directAddress = address;
            var connect = start;
            start = null;
            connect.accept(address);
        } else if (direct != nextDirect) {
            closed = true;
            LogManager.getLogger(LocalSession.class).info("直连规则已变化，关闭受影响的业务连接：目标={}，路由={} → {}",
                    target, direct ? "直连" : "代理", nextDirect ? "直连" : "代理");
            cancelLookup();
            // 只取消本次业务对应的目标套接字或协议流，共享主连接保持不变。
            if (remote != null) Transport.abort(remote);
            browser.close();
        }
    }

    private void cancelLookup() {
        var previous = lookup;
        lookup = null;
        if (previous != null) previous.cancel(false);
    }
}
