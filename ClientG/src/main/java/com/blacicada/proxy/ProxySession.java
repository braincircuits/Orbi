package com.blacicada.proxy;

import com.blacicada.common.Authority;
import io.netty.channel.Channel;
import io.netty.util.concurrent.Future;

/** 协议会话只负责创建隧道，配置选择由上层路由负责。 */
public interface ProxySession extends AutoCloseable {
    default Future<? extends Channel> open(Authority target) { return open(target, false); }
    Future<? extends Channel> open(Authority target, boolean udp);
    /** 测量当前服务端连接的往返时延，单位为毫秒，不创建目标网站隧道。 */
    Future<Double> latency();
    long connectionCount();
    String connectionState();
    String lastError();
    String stage();
    @Override void close();
}
