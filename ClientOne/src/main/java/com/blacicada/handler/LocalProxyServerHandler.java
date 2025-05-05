package com.blacicada.handler;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.AttributeKey;

import java.util.Collection;
import java.util.concurrent.CopyOnWriteArraySet;

import static com.blacicada.handler.LocalProxyServerInit.idMapChannel;

public class LocalProxyServerHandler extends ChannelInboundHandlerAdapter
{

    public final static Collection<Integer> ids = new CopyOnWriteArraySet<>();
    private final int id;
    private final Channel serverChannel;
    public LocalProxyServerHandler(int incrementAndGet, Channel serverChannel)
    {
        id = incrementAndGet;
        this.serverChannel=serverChannel;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        ByteBuf bufId = Unpooled.copyInt(id);
        serverChannel.writeAndFlush(Unpooled.copiedBuffer(bufId, byteBuf)).addListener(future -> {
            if (!future.isSuccess())
            {
                System.out.println("发送失败");
            }
        });
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception
    {
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
        //就是ctx.channel();
        Channel remove = idMapChannel.remove(String.valueOf(id));
        if (remove != null)
        {
            Boolean isRemoteClose = (Boolean) remove.attr(AttributeKey.valueOf(String.valueOf(id))).get();
            Boolean isRemoteClosea = (Boolean) ctx.channel().attr(AttributeKey.valueOf(String.valueOf(id))).get();
            if (isRemoteClose != null)
            {
                System.out.println("服务端远程关闭" + isRemoteClose + id);
            } else if (serverChannel.isActive())
            {
                System.out.println("代理连接断开");
            } else
            {
                System.out.println("" +
                        "本地关闭" + serverChannel.isActive() + isRemoteClose + id + isRemoteClosea + "  " + System.currentTimeMillis());
                if (serverChannel.isActive())
                {
                    serverChannel.writeAndFlush(Unpooled.copyInt(id)).addListener(future -> {
                        if (!future.isSuccess())
                        {
                            System.out.println("通过代理连接发送失败");
                        }
                    });
                }
            }
        } else
        {
            System.out.println("未知关闭");
            Boolean isRemoteClose = (Boolean) ctx.channel().attr(AttributeKey.valueOf(String.valueOf(id))).get();
            System.out.println("channel为null===");
            if (isRemoteClose != null && isRemoteClose)
            {
                System.out.println("严重问题============");
            }
        }
    }
}
