package com.blacicada.common.h3;

import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;
import io.netty.handler.codec.http3.Http3ErrorCode;
import io.netty.handler.codec.quic.QuicStreamChannel;

/** 完整关闭流时停止接收，释放未读数据占用的 QUIC 连接级流控额度。 */
public final class QuicStreamCleanupHandler extends ChannelOutboundHandlerAdapter {
    @Override public void close(ChannelHandlerContext ctx, ChannelPromise promise) {
        QuicStreamChannel stream = (QuicStreamChannel) ctx.channel();
        if (stream.isActive() && !stream.isInputShutdown()) {
            // Netty 的 close 发送 FIN，但未必丢弃尚未读取的接收数据。
            // 只在完整关闭时停止输入，正常 shutdownOutput 半关闭仍允许对端继续回传。
            stream.shutdownInput((int) Http3ErrorCode.H3_REQUEST_CANCELLED.code())
                    .addListener(ignored -> ctx.close(promise));
        } else {
            ctx.close(promise);
        }
    }
}
