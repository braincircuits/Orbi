package com.blacicada.proxy;

import com.blacicada.common.OutboundNetwork;
import com.blacicada.common.DnsTunnel;
import com.blacicada.config.DirectRoutes;
import com.blacicada.common.UdpTunnel;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.LengthFieldPrepender;
import io.netty.handler.timeout.IdleStateEvent;
import io.netty.resolver.dns.*;
import io.netty.util.NetUtil;
import io.netty.util.concurrent.Future;
import io.netty.util.concurrent.Promise;
import io.netty.util.concurrent.ScheduledFuture;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.*;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;
import org.apache.logging.log4j.LogManager;

/** TUN 普通 DNS 按查询域名分流；代理使用服务端系统 DNS，直连使用本机系统 DNS。 */
final class KernelDns {
    static final String SOURCE_HEADER = "x-network-source";
    private static final int MAX_QUERIES = 256, MAX_CACHE = 1024, MAX_NAMES = 8192;
    private final OutboundNetwork network;
    private final DnsAddressResolverGroup resolver;
    private final DnsServerAddressStreamProvider servers;
    private final int timeoutMillis;
    private final LongSupplier clock;
    private final Map<String, Association> names = new LinkedHashMap<>();
    private final Map<String, Cached> cache = new LinkedHashMap<>();
    private final SessionRouter session;
    private DirectRoutes routes;
    private final Map<Promise<byte[]>, byte[]> pending = new HashMap<>();
    private record Association(String domain, long expires) {}
    private record Cached(byte[] bytes, DnsMessage message, long created, long expires) {}

    KernelDns(OutboundNetwork network, DnsAddressResolverGroup resolver, DnsServerAddressStreamProvider servers,
              SessionRouter session, DirectRoutes routes) {
        this(network, resolver, servers, 3000, System::nanoTime, session, routes);
    }
    KernelDns(OutboundNetwork network, DnsAddressResolverGroup resolver, DnsServerAddressStreamProvider servers,
              int timeoutMillis, LongSupplier clock) {
        this(network, resolver, servers, timeoutMillis, clock, null, null);
    }
    private KernelDns(OutboundNetwork network, DnsAddressResolverGroup resolver, DnsServerAddressStreamProvider servers,
                      int timeoutMillis, LongSupplier clock, SessionRouter session, DirectRoutes routes) {
        this.network = network; this.resolver = resolver; this.servers = servers;
        this.timeoutMillis = timeoutMillis; this.clock = clock; this.session = session; this.routes = routes;
    }
    /** 配置切换在共用事件循环中执行；旧回答不能更新新出口下的缓存和域名关联。 */
    void apply(DirectRoutes routes) { this.routes = routes; reset(); }
    void reset() {
        // 应用可能仍缓存真实 IP；保留尚未过期的关联，便于新连接按最新域名规则分流。
        cache.clear();
        for (var request : List.copyOf(pending.entrySet()))
            request.getKey().trySuccess(DnsMessage.failure(request.getValue(), 2));
    }

    String domain(String ip) {
        if (!NetUtil.isValidIpV4Address(ip) && !NetUtil.isValidIpV6Address(ip)) return null;
        String key = InetAddress.ofLiteral(ip).getHostAddress();
        Association value = names.get(key);
        if (value == null) return null;
        if (clock.getAsLong() - value.expires >= 0) { names.remove(key); return null; }
        return value.domain;
    }
    void remember(DnsMessage response) {
        long now = clock.getAsLong();
        names.entrySet().removeIf(entry -> now - entry.getValue().expires >= 0);
        // 域名关联只接受能用于连接目标的主机名，其他 DNS 记录仍原样转发。
        String domain;
        try { domain = com.blacicada.config.DirectRoutes.normalizeHost(response.question.name()); }
        catch (IllegalArgumentException e) { return; }
        for (var entry : response.addresses().entrySet()) {
            names.remove(entry.getKey());
            if (entry.getValue() > 0) names.put(entry.getKey(), new Association(domain,
                    now + TimeUnit.SECONDS.toNanos(entry.getValue())));
        }
        trim(names, MAX_NAMES);
    }
    private static void trim(Map<?, ?> values, int maximum) {
        while (values.size() > maximum) values.remove(values.keySet().iterator().next());
    }
    static void framing(ChannelPipeline pipeline) {
        pipeline.addLast(new LengthFieldBasedFrameDecoder(65537, 0, 2, 0, 2));
        pipeline.addLast(new LengthFieldPrepender(2));
    }
    ChannelHandler handler(boolean udp) { return new QueryHandler(udp); }

    private final class QueryHandler extends SimpleChannelInboundHandler<ByteBuf> {
        private final boolean udp;
        private final Set<Future<byte[]>> requests = new HashSet<>();
        private boolean inputClosed;
        QueryHandler(boolean udp) { this.udp = udp; }
        @Override protected void channelRead0(ChannelHandlerContext ctx, ByteBuf data) {
            if (!ctx.channel().isWritable() || requests.size() >= 32) { ctx.close(); return; }
            byte[] bytes = new byte[data.readableBytes()]; data.readBytes(bytes);
            Future<byte[]> request = query(ctx.channel().eventLoop(), bytes, udp, ctx.channel());
            requests.add(request);
            request.addListener(done -> {
                requests.remove(request);
                if (ctx.channel().isActive() && done.isSuccess())
                    ctx.writeAndFlush(Unpooled.wrappedBuffer(request.getNow())).addListener(ChannelFutureListener.CLOSE_ON_FAILURE);
                if (inputClosed && requests.isEmpty()) ctx.close();
            });
        }
        @Override public void channelInactive(ChannelHandlerContext ctx) {
            for (var request : List.copyOf(requests)) request.cancel(false);
            ctx.fireChannelInactive();
        }
        @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
            if (event instanceof IdleStateEvent) ctx.close();
            else if (event == ChannelInputShutdownEvent.INSTANCE) {
                inputClosed = true; if (requests.isEmpty()) ctx.close();
            } else ctx.fireUserEventTriggered(event);
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { ctx.close(); }
    }

    Future<byte[]> query(EventLoop loop, byte[] bytes, boolean udp) { return query(loop, bytes, udp, null); }
    private Future<byte[]> query(EventLoop loop, byte[] bytes, boolean udp, Channel browser) {
        DnsMessage question;
        try { question = new DnsMessage(bytes, false); }
        catch (RuntimeException e) { return loop.newSucceededFuture(DnsMessage.failure(bytes, 1)); }
        if (pending.size() >= MAX_QUERIES) return loop.newSucceededFuture(DnsMessage.failure(bytes, 2));
        // DNS 尚无结果 IP，不为匹配网段规则额外发起一次本机解析。
        final boolean proxy;
        try {
            proxy = session != null && !routes.matches(question.question.name());
            if (proxy) new DnsTunnel(question.question.name(), 0);
        } catch (IllegalArgumentException e) { return loop.newSucceededFuture(DnsMessage.failure(bytes, 1)); }
        List<InetSocketAddress> upstreams = new ArrayList<>();
        if (!proxy) try {
            var stream = servers.nameServerAddressStream(question.question.name());
            for (int i = 0; i < Math.min(stream.size(), 4); i++) {
                var address = stream.next();
                if (!address.isUnresolved() && !upstreams.contains(address)) upstreams.add(address);
            }
        } catch (RuntimeException e) {
            LogManager.getLogger(KernelDns.class).warn("读取系统 DNS 失败：{}", e.toString());
        }
        if (!proxy && upstreams.isEmpty()) return loop.newSucceededFuture(DnsMessage.failure(bytes, 2));
        // 只缓存无附加选项的标准查询，避免跨请求复用 EDNS Cookie、签名等状态。
        String key = question.additional == 0 ? proxy + ":" + udp + ":" + upstreams + ":"
                + Base64.getEncoder().encodeToString(Arrays.copyOfRange(bytes, 2, bytes.length)) : null;
        long now = clock.getAsLong();
        cache.entrySet().removeIf(entry -> now - entry.getValue().expires >= 0);
        Cached stored = key == null ? null : cache.get(key);
        if (stored != null) {
            byte[] answer = stored.bytes.clone();
            long elapsed = Math.max(0, (now - stored.created + 999_999_999L) / 1_000_000_000L);
            ByteBuf buffer = Unpooled.wrappedBuffer(answer);
            try {
                buffer.setShort(0, question.id);
                for (var record : stored.message.records) if (record.type() != 41)
                    buffer.setInt(record.ttlOffset(), (int) Math.max(0, record.ttl() - elapsed));
            } finally { buffer.release(); }
            remember(new DnsMessage(answer, true));
            return loop.newSucceededFuture(answer);
        }
        Promise<byte[]> result = loop.newPromise(); pending.put(result, bytes);
        result.addListener(done -> pending.remove(result));
        new Exchange(loop, bytes, udp, upstreams, key, result, proxy, browser).next();
        return result;
    }

    private final class Exchange {
        final EventLoop loop;
        final byte[] original, outgoing;
        final DnsMessage question;
        final boolean udp, proxy;
        final Channel browser;
        final List<InetSocketAddress> upstreams;
        final String cacheKey;
        final Promise<byte[]> result;
        final List<String> failures = new ArrayList<>();
        int index, generation;
        Channel channel;
        Future<Channel> opening;
        ScheduledFuture<?> timer;
        Exchange(EventLoop loop, byte[] bytes, boolean udp,
                 List<InetSocketAddress> upstreams, String cacheKey, Promise<byte[]> result, boolean proxy, Channel browser) {
            this.loop = loop; original = bytes; outgoing = bytes.clone(); this.udp = udp;
            this.upstreams = upstreams; this.cacheKey = cacheKey; this.result = result;
            this.proxy = proxy; this.browser = browser;
            int id = ThreadLocalRandom.current().nextInt(65536);
            outgoing[0] = (byte) (id >>> 8); outgoing[1] = (byte) id;
            question = new DnsMessage(outgoing, false);
            result.addListener(done -> cleanup());
        }
        void cleanup() {
            generation++;
            if (timer != null) { timer.cancel(false); timer = null; }
            if (opening != null) { opening.cancel(false); opening = null; }
            if (channel != null) { Channel old = channel; channel = null; old.close(); }
        }
        void failed(int attempt, String reason) {
            if (attempt != generation || result.isDone()) return;
            String upstream = proxy ? "服务端上游序号=" + (index - 1) : "上游=" + upstreams.get(index - 1);
            failures.add(upstream + "，原因=" + reason);
            next();
        }
        void next() {
            cleanup();
            if (result.isDone()) return;
            if (index == (proxy ? DnsTunnel.MAX_SERVERS : upstreams.size())) {
                LogManager.getLogger(KernelDns.class).warn("系统 DNS 查询失败：域名={}，类型={}，传输={}，路由={}，尝试详情={}",
                        question.question.name(), question.question.type(), udp ? "UDP" : "TCP", proxy ? "代理" : "直连", failures);
                result.trySuccess(DnsMessage.failure(original, 2)); return;
            }
            int serverIndex = index++;
            int attempt = generation;
            long openingTimeout = proxy ? Math.max(timeoutMillis,
                    session.config().profile(session.config().defaultConnectionId()).config().connectTimeoutMillis() * 2L) : timeoutMillis;
            timer = loop.schedule(() -> failed(attempt, "建立连接或等待响应超时（" + openingTimeout + " 毫秒）"),
                    openingTimeout, TimeUnit.MILLISECONDS);
            InetSocketAddress address = proxy ? null : upstreams.get(serverIndex);
            if (proxy) opening = session.openDns(new DnsTunnel(question.question.name(), serverIndex), browser, udp);
            else if (udp) opening = UdpTunnel.connect(loop, resolver, address, network);
            else {
                var connecting = new Bootstrap().group(loop).channelFactory(network::tcp)
                        .option(ChannelOption.AUTO_READ, false).option(ChannelOption.CONNECT_TIMEOUT_MILLIS, timeoutMillis)
                        .handler(new ChannelInboundHandlerAdapter()).connect(address);
                channel = connecting.channel();
                Promise<Channel> connected = loop.newPromise();
                connecting.addListener(f -> {
                    if (f.isSuccess()) connected.trySuccess(connecting.channel());
                    else connected.tryFailure(f.cause());
                });
                opening = connected;
            }
            Future<Channel> request = opening;
            request.addListener(done -> {
                if (attempt != generation || result.isDone()) {
                    if (done.isSuccess()) request.getNow().close(); return;
                }
                opening = null;
                if (!done.isSuccess()) { failed(attempt, "建立连接失败：" + done.cause()); return; }
                Channel upstream = request.getNow(); channel = upstream;
                if (proxy) {
                    timer.cancel(false);
                    timer = loop.schedule(() -> failed(attempt, "等待 DNS 响应超时（" + timeoutMillis + " 毫秒）"),
                            timeoutMillis, TimeUnit.MILLISECONDS);
                }
                if (udp && proxy) UdpTunnel.addFraming(upstream.pipeline());
                if (!udp) framing(upstream.pipeline());
                upstream.pipeline().addLast(new SimpleChannelInboundHandler<ByteBuf>() {
                    @Override protected void channelRead0(ChannelHandlerContext ctx, ByteBuf data) {
                        if (attempt != generation || result.isDone()) return;
                        byte[] bytes = new byte[data.readableBytes()]; data.readBytes(bytes);
                        DnsMessage response;
                        try { response = new DnsMessage(bytes, true); }
                        catch (RuntimeException e) { if (!udp) failed(attempt, "DNS 响应无效：" + e); else ctx.read(); return; }
                        if (!response.matches(question)) { ctx.read(); return; }
                        bytes[0] = original[0]; bytes[1] = original[1];
                        remember(response);
                        if (cacheKey != null && bytes.length <= 4096 && response.cacheable()) {
                            long ttl = response.records.stream().filter(r -> r.type() != 41)
                                    .mapToLong(DnsMessage.Record::ttl).min().orElse(0);
                            if (ttl > 0) {
                                long now = clock.getAsLong(); cache.remove(cacheKey);
                                cache.put(cacheKey, new Cached(bytes.clone(), response, now, now + TimeUnit.SECONDS.toNanos(ttl)));
                                trim(cache, MAX_CACHE);
                            }
                        }
                        result.trySuccess(bytes);
                    }
                    @Override public void channelInactive(ChannelHandlerContext ctx) { failed(attempt, "收到 DNS 响应前连接已关闭"); }
                    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) { failed(attempt, "DNS 通道异常：" + cause); }
                });
                upstream.writeAndFlush(Unpooled.wrappedBuffer(outgoing)).addListener(sent -> {
                    if (!sent.isSuccess()) failed(attempt, "发送 DNS 查询失败：" + sent.cause());
                });
                upstream.read();
            });
        }
    }
}
