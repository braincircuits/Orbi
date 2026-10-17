package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.DnsTunnel;
import io.netty.channel.Channel;
import io.netty.util.concurrent.Future;

/**
 * 协议会话只负责创建隧道，配置选择由上层路由负责。
 */
public interface ProxySession extends AutoCloseable {
    /**
     * 只允许固定模板的数值状态码进入日志，任意异常原文仅以类型描述。
     */
    static String failureDescription(Throwable failure) {
        String message = failure.getMessage();
        return message != null && message.matches("代理 CONNECT 失败：[1-5][0-9]{2}")
                ? message : failure.getClass().getSimpleName();
    }

    default Future<? extends Channel> open(Authority target) {
        return open(target, false);
    }

    default Future<? extends Channel> open(Authority target, boolean udp) {
        return open(target, udp, null);
    }

    Future<? extends Channel> open(Authority target, boolean udp, DnsTunnel dns);

    /**
     * 测量当前服务端连接的往返时延，单位为毫秒，不创建目标网站隧道。
     */
    Future<Double> latency();

    long connectionCount();

    String connectionState();

    String lastError();

    String stage();

    @Override
    void close();
}
