package com.blacicada.proxy;

import com.blacicada.config.DirectRoutes;
import io.netty.channel.ChannelHandlerContext;
import io.netty.handler.ssl.AbstractSniHandler;
import io.netty.util.NetUtil;
import io.netty.util.concurrent.Future;
import io.netty.util.concurrent.ScheduledFuture;

import java.util.function.Function;
import java.util.function.Supplier;
import java.util.concurrent.TimeUnit;

/** 复用 Netty 解析有界的 ClientHello，出口就绪后原样释放缓存的 TLS 数据。 */
final class TunTlsRouter extends AbstractSniHandler<Void> {
    private final Function<String, Future<Void>> route;
    private final Supplier<String> dnsDomain;
    private Future<Void> selected;
    private ScheduledFuture<?> deadline;

    TunTlsRouter(Function<String, Future<Void>> route, Supplier<String> dnsDomain) {
        // 连接总超时由本地请求入口管理，避免叠加独立的 TLS 握手超时。
        super(65536, 0);
        this.route = route;
        this.dnsDomain = dnsDomain;
    }

    @Override
    public void handlerAdded(ChannelHandlerContext ctx) throws Exception {
        super.handlerAdded(ctx);
        // 443 端口也可能运行服务端先发数据的协议，不能无限等待 ClientHello。
        deadline = ctx.executor().schedule(() -> {
            if (!ctx.channel().isActive()) return;
            Future<Void> result = select(null);
            result.addListener(done -> onLookupComplete(ctx, null, result));
        }, 250, TimeUnit.MILLISECONDS);
    }

    private Future<Void> select(String domain) {
        if (selected == null) {
            if (deadline != null) deadline.cancel(false);
            // 连接携带的 SNI 比共享 IP 的历史 DNS 关联更准确；无法读取时才查询 DNS 关联。
            selected = route.apply(domain == null ? dnsDomain.get() : domain);
        }
        return selected;
    }

    @Override
    protected Future<Void> lookup(ChannelHandlerContext ctx, String hostname) {
        String domain = null;
        if (hostname != null) try {
            String normalized = DirectRoutes.normalizeHost(hostname);
            if (!NetUtil.isValidIpV4Address(normalized) && !NetUtil.isValidIpV6Address(normalized)) domain = normalized;
        } catch (IllegalArgumentException ignored) {
            // 无效或缺失的 SNI 继续按原始 IP 分流。
        }
        return select(domain);
    }

    @Override
    protected void onLookupComplete(ChannelHandlerContext ctx, String hostname, Future<Void> result) {
        if (result.isSuccess()) {
            if (ctx.pipeline().context(this) != null) ctx.pipeline().remove(this);
        }
        else ctx.close();
    }

    @Override
    protected void handlerRemoved0(ChannelHandlerContext ctx) throws Exception {
        if (deadline != null) deadline.cancel(false);
        super.handlerRemoved0(ctx);
    }
}
