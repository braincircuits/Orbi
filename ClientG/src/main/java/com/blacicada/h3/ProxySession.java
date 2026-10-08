package com.blacicada.h3;

import com.blacicada.common.h3.Authority;
import io.netty.channel.Channel;
import io.netty.util.concurrent.Future;

/** 协议会话只负责创建隧道，配置选择由上层路由负责。 */
public interface ProxySession extends AutoCloseable {
    Future<? extends Channel> open(Authority target);
    long connectionCount();
    String connectionState();
    String lastError();
    default String stage() { return connectionState(); }
    @Override void close();
}
