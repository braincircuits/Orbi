package com.blacicada.handler;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.AttributeKey;

import java.util.Map;


public class ProxyServerHandler extends ChannelInboundHandlerAdapter
{
    private final int id;
    private final Channel oneChannel;
    private final Map<String, Channel> idMapChannel;

    public ProxyServerHandler(int id, Channel oneChannel, Map<String, Channel> idMapChannel)
    {
        this.id = id;
        this.oneChannel = oneChannel;
        this.idMapChannel = idMapChannel;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        ByteBuf byteBufId = Unpooled.copyInt(id);
        ctx.write(Unpooled.wrappedBuffer(byteBufId, byteBuf));
    }

    @Override
    public void channelReadComplete(ChannelHandlerContext ctx) throws Exception
    {
        ctx.flush();
        super.channelReadComplete(ctx);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception
    {
        System.out.println(cause.getMessage());
        StackTraceElement[] stackTrace = cause.getStackTrace();
        for (StackTraceElement stackTraceElement : stackTrace)
        {
            System.out.println(stackTraceElement);
        }
        Channel channel = ctx.channel();
        if (channel.isActive())
        {
            channel.close();
        }
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception
    {
        System.out.println(idMapChannel.size());
        idMapChannel.remove(String.valueOf(id));
        Boolean isRemoteClose = (Boolean) ctx.channel().attr(AttributeKey.valueOf(String.valueOf(id))).get();
        if (isRemoteClose != null && oneChannel.isActive())
        {
            System.out.println("客户端远程关闭" + isRemoteClose + id);
        } else if (oneChannel.isActive())
        {
            System.out.println("代理连接断开");
        } else
        {
            System.out.println("目标关闭" + id);
            oneChannel.writeAndFlush(Unpooled.copyInt(id)).addListener(future -> {
                if (!future.isSuccess())
                {
                    System.out.println("opppppppppp");
                }
            });
        }
    }
}
