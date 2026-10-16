package com.blacicada.common.h2;

import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.handler.codec.http2.*;
import io.netty.util.AttributeKey;
import io.netty.util.ReferenceCountUtil;

/**
 * 将 HTTP/2 DATA 与隧道字节流互转，显式传递半关闭。
 */
public final class H2DataCodec extends ChannelDuplexHandler {
    public enum Signal {FIN}

    public static final AttributeKey<Boolean> INPUT_CLOSED = AttributeKey.valueOf("h2.inputClosed");

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (msg instanceof Http2DataFrame frame) {
            boolean end = frame.isEndStream();
            ByteBuf data = frame.content().retain();
            frame.release();
            ctx.fireChannelRead(data);
            if (end) {
                ctx.channel().attr(INPUT_CLOSED).set(true);
                ctx.fireUserEventTriggered(ChannelInputShutdownEvent.INSTANCE);
            }
        } else if (msg instanceof Http2UnknownFrame) {
            ReferenceCountUtil.release(msg);
            // 未知扩展帧不影响隧道；续读交给转发层或 DNS 查询处理器，不能绕过反压。
        } else {
            ReferenceCountUtil.release(msg);
            ctx.fireExceptionCaught(new java.io.IOException("CONNECT 成功后收到非预期 HTTP/2 帧"));
        }
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
        if (event instanceof Http2ResetFrame) ctx.close();
        else ctx.fireUserEventTriggered(event);
    }

    @Override
    public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) {
        if (msg instanceof ByteBuf data) ctx.write(new DefaultHttp2DataFrame(data), promise);
        else if (msg == Signal.FIN) ctx.write(new DefaultHttp2DataFrame(true), promise);
        else ctx.write(msg, promise);
    }
}
