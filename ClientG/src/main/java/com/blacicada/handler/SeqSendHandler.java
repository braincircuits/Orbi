package com.blacicada.handler;

import io.netty.buffer.Unpooled;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPipeline;
import io.netty.channel.ChannelPromise;

import static com.blacicada.common.Constant.seqKey;

public class SeqSendHandler extends ChannelOutboundHandlerAdapter
{
    @Override
    public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception
    {
        Integer seq = ctx.channel().attr(seqKey).get();
        ctx.write(Unpooled.copyInt(seq));
        ChannelPipeline pipeline = ctx.pipeline();
        pipeline.remove(this.getClass());
        super.write(ctx, msg, promise);
    }
}
