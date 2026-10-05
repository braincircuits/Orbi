package com.blacicada.common.h3;

import io.netty.buffer.ByteBuf;
import io.netty.channel.*;
import io.netty.handler.codec.http3.*;
import io.netty.util.ReferenceCountUtil;

/** Installed after CONNECT succeeds. Application bytes are always HTTP/3 DATA frames. */
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
            ctx.fireExceptionCaught(new IllegalStateException("Unexpected frame after CONNECT"));
        }
    }
    @Override public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) {
        if (msg instanceof ByteBuf data) {
            // Give the frame its own zero-based view of the readable bytes. In particular,
            // HTTP decoder leftovers can retain a nonzero readerIndex after CONNECT.
            ByteBuf payload = data.retainedSlice();
            data.release();
            ctx.write(new DefaultHttp3DataFrame(payload), promise);
        } else ctx.write(msg, promise);
    }
}
