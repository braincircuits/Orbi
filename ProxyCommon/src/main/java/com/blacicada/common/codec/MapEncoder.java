package com.blacicada.common.codec;

import com.blacicada.common.util.key.KeyUtil;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;
import io.netty.util.ReferenceCountUtil;

public class MapEncoder extends ChannelOutboundHandlerAdapter
{
    private static byte[] byteMap = KeyUtil.byteMap;
    private static int num = byteMap.length;
    private int seq = 0;

    public MapEncoder()
    {
        
    }
    public MapEncoder(int seq)
    {
        this.seq=seq;
    }

    @Override
    public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        byte[] bytes = new byte[byteBuf.readableBytes()];
        byteBuf.getBytes(byteBuf.readerIndex(), bytes);
        for (int i = 0; i < bytes.length; i++)
        {
            bytes[i] -= byteMap[seq];
            seq++;
            if (seq == num)
            {
                seq = 0;
            }
        }
        ReferenceCountUtil.release(msg);
        ctx.write(Unpooled.copiedBuffer(bytes), promise);
    }

}
