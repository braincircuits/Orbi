package com.blacicada.handler;

import com.blacicada.common.netty.NettyCommon;
import io.netty.buffer.ByteBuf;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.ReferenceCountUtil;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

public class ProxyBackendHandler extends ChannelInboundHandlerAdapter
{
    private final Channel inboundChannel;
    private final static Logger logger = LogManager.getLogger(ProxyBackendHandler.class);

    public ProxyBackendHandler(Channel inboundChannel)
    {
        this.inboundChannel = inboundChannel;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        if (inboundChannel.isActive())
        {
            inboundChannel.writeAndFlush(msg).addListener((ChannelFutureListener) future -> {
                if (!future.isSuccess())
                {
                    logger.info("数据写入请求channel失败:" + inboundChannel.isActive() + "open" + inboundChannel.isOpen() + "引用:" + byteBuf.refCnt());
                    future.channel().close();
                }
            });
        } else
        {
            ReferenceCountUtil.release(msg);
            NettyCommon.closeChannel(ctx.channel());
        }
    }


    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception
    {
        NettyCommon.closeChannel(inboundChannel);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception
    {
        logger.info("001=" + cause.getMessage());
        NettyCommon.closeChannel(ctx.channel());
    }
}
