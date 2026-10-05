package com.blacicada.common.h3;

import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.handler.codec.http3.*;
import io.netty.util.ReferenceCountUtil;

/** 在 CONNECT 成功后安装；应用数据始终封装为 HTTP/3 DATA 帧。 */
public final class H3DataCodec extends ChannelDuplexHandler {
    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (msg instanceof Http3DataFrame frame) {
            ByteBuf data = frame.content().retain();
            frame.release();
            ctx.fireChannelRead(data);
        } else if (msg instanceof Http3UnknownFrame) {
            ReferenceCountUtil.release(msg);
            ctx.read();
        } else {
            ReferenceCountUtil.release(msg);
            ctx.fireExceptionCaught(new IllegalStateException("CONNECT 成功后收到非预期帧"));
        }
    }
    @Override public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) {
        if (msg instanceof ByteBuf data) {
            // 为帧创建从零开始的可读字节视图；
            // 尤其是 CONNECT 后 HTTP 解码器的剩余数据可能保留非零 readerIndex。
            ByteBuf payload = data.retainedSlice();
            data.release();
            ctx.write(new DefaultHttp3DataFrame(payload), promise);
        } else ctx.write(msg, promise);
    }
}
