package com.blacicada.common;

import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.handler.codec.ByteToMessageCodec;
import io.netty.handler.codec.CorruptedFrameException;

import java.util.List;

/**
 * UDP 报文以两字节无符号大端长度开头，长度不包含前缀。
 */
public final class UdpFrameCodec extends ByteToMessageCodec<ByteBuf> {
    // 统一采用 IPv4 的最大 UDP 负载，IPv6 也遵守同一上限。
    public static final int MAX_PAYLOAD = 65507;

    @Override
    protected void decode(ChannelHandlerContext ctx, ByteBuf input, List<Object> output) {
        if (input.readableBytes() < 2) return;
        int length = input.getUnsignedShort(input.readerIndex());
        if (length > MAX_PAYLOAD) throw new CorruptedFrameException("UDP 报文超过长度限制");
        if (input.readableBytes() < length + 2) return;
        input.skipBytes(2);
        output.add(input.readRetainedSlice(length));
    }

    @Override
    protected void decodeLast(ChannelHandlerContext ctx, ByteBuf input, List<Object> output) {
        decode(ctx, input, output);
        if (input.isReadable()) throw new CorruptedFrameException("UDP 隧道在报文完整到达前关闭");
    }

    @Override
    protected void encode(ChannelHandlerContext ctx, ByteBuf message, ByteBuf output) {
        int length = message.readableBytes();
        if (length > MAX_PAYLOAD) throw new CorruptedFrameException("UDP 报文超过长度限制");
        output.writeShort(length).writeBytes(message, message.readerIndex(), length);
    }
}
