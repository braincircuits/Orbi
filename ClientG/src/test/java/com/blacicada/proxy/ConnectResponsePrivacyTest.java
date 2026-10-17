package com.blacicada.proxy;

import com.blacicada.common.Authority;
import com.blacicada.common.DnsTunnel;
import com.blacicada.common.OutboundNetwork;
import com.blacicada.common.ProxyConfig;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.http2.DefaultHttp2Headers;
import io.netty.handler.codec.http2.DefaultHttp2HeadersFrame;
import io.netty.handler.codec.http3.DefaultHttp3HeadersFrame;
import io.netty.util.concurrent.Promise;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class ConnectResponsePrivacyTest {
    @Test
    void failureDescriptionsOnlyKeepCompleteNumericConnectStatus() {
        assertEquals("代理 CONNECT 失败：407", ProxySession.failureDescription(new java.io.IOException("代理 CONNECT 失败：407")));
        for (String message : new String[]{"Bearer unregistered-token-secret", "代理 CONNECT 失败：407 token-secret", "代理 CONNECT 失败：407\nAuthorization: token-secret"}) {
            assertEquals("IOException", ProxySession.failureDescription(new java.io.IOException(message)));
        }
    }

    @Test
    void invalidStatusValuesNeverEnterExceptionsAndValidStatusRemainsUseful() throws Exception {
        var group = OutboundNetwork.DEFAULT.newGroup();
        var loop = group.next();
        var values = new Properties();
        values.setProperty("server.host", "127.0.0.1");
        values.setProperty("password", "test-only-password");
        var config = new ProxyConfig(values, Path.of("."));
        try (var h2 = new Http2Session(loop, config, null); var h3 = new Http3Session(loop, config, null)) {
            for (boolean http3 : new boolean[]{false, true}) {
                for (String status : new String[]{"reflected-token-secret", "1reflected-token-secret", "2ab", "407"}) {
                    Promise<?> result;
                    ChannelInboundHandlerAdapter handler;
                    var target = new Authority("example.test", 443);
                    if (http3) {
                        result = loop.newPromise();
                        var type = Class.forName(Http3Session.class.getName() + "$ConnectResponse");
                        var constructor = type.getDeclaredConstructor(Http3Session.class, Promise.class, Authority.class, boolean.class, DnsTunnel.class);
                        constructor.setAccessible(true);
                        handler = (ChannelInboundHandlerAdapter) constructor.newInstance(h3, result, target, false, null);
                    } else {
                        var requestType = Class.forName(Http2Session.class.getName() + "$Request");
                        var requestConstructor = requestType.getDeclaredConstructor(Http2Session.class, Authority.class, boolean.class, DnsTunnel.class);
                        requestConstructor.setAccessible(true);
                        var request = requestConstructor.newInstance(h2, target, false, null);
                        var field = requestType.getDeclaredField("result");
                        field.setAccessible(true);
                        result = (Promise<?>) field.get(request);
                        var type = Class.forName(Http2Session.class.getName() + "$Response");
                        var constructor = type.getDeclaredConstructor(Http2Session.class, requestType);
                        constructor.setAccessible(true);
                        handler = (ChannelInboundHandlerAdapter) constructor.newInstance(h2, request);
                    }
                    // 只检验响应头失败路径，不安装会启动真实流计时器的处理器。
                    var channel = new EmbeddedChannel(new ChannelInboundHandlerAdapter());
                    try {
                        Object frame;
                        if (http3) {
                            var headers = new DefaultHttp3HeadersFrame();
                            headers.headers().status(status);
                            frame = headers;
                        } else frame = new DefaultHttp2HeadersFrame(new DefaultHttp2Headers(false).status(status));
                        handler.channelRead(channel.pipeline().firstContext(), frame);
                        assertTrue(result.isDone());
                        assertFalse(result.isSuccess());
                        assertEquals("代理 CONNECT 失败：" + (status.equals("407") ? "407" : "无效状态码"), result.cause().getMessage());
                    } finally {
                        channel.finishAndReleaseAll();
                    }
                }
            }
        } finally {
            group.shutdownGracefully(0, 1, TimeUnit.SECONDS).syncUninterruptibly();
        }
    }
}
