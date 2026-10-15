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
            int error = (int) Http3ErrorCode.H3_REQUEST_CANCELLED.code();
            // 已半关闭输出的流再次完整关闭时，需要重置两个方向。
            // 否则 FIN 已确认后再停止输入，底层可能不再触发回收，永久占用对端流额度。
            // 输出尚未关闭时仍保留 FIN 路径，避免丢弃已经写入传输层的响应数据。
            var shutdown = stream.isOutputShutdown() ? stream.shutdown(error) : stream.shutdownInput(error);
            shutdown.addListener(ignored -> ctx.close(promise));
        } else {
            ctx.close(promise);
        }
    }
}
