package com.blacicada.common.codec;

import com.blacicada.common.util.key.KeyUtil;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.ReferenceCountUtil;

public class MapDecoder extends ChannelInboundHandlerAdapter
{
    private static byte[] byteMap = KeyUtil.byteMap;
    public final static int num = byteMap.length;
    private int seq = -1;

    public int getSeq()
    {
        return seq;
    }
    public MapDecoder()
    {
    }

    public MapDecoder(int seq)
    {
        this.seq = seq;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        byte[] bytes = new byte[byteBuf.readableBytes()];
        byteBuf.getBytes(byteBuf.readerIndex(), bytes);
        for (int i = 0; i < bytes.length; i++)
        {
            bytes[i] += byteMap[seq];
            seq++;
            if (seq == num)
            {
                seq = 0;
            }
        }
        ReferenceCountUtil.release(msg);
        ctx.fireChannelRead(Unpooled.copiedBuffer(bytes));
    }
}


