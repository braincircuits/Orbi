package com.blacicada.handler;

import io.netty.buffer.ByteBuf;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.AttributeKey;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import static com.blacicada.OneClient.b;
import static com.blacicada.OneClient.serverChannel;
import static com.blacicada.handler.LocalProxyServerInit.idMapChannel;


public class OneClientHandler extends ChannelInboundHandlerAdapter
{
    
    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg)
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        int id = byteBuf.readInt();
        System.out.println(id+"  end"+byteBuf.readableBytes());
        if (byteBuf.readableBytes() == 0)
        {
            // 说明远程服务此id的代理连接已经关闭，此时需要关闭本地对应的连接
            Channel removeChannel = idMapChannel.get(String.valueOf(id));
            if (removeChannel != null)
            {
                System.out.println("收到远程关闭"+id);
                // 说明是远程关闭
                removeChannel.attr(AttributeKey.valueOf(String.valueOf(id))).set(true);
                removeChannel.close();
            } else
            {
                System.out.println("本地代理连接已关闭"+id);
            }
            return;
        }
        Channel channel = idMapChannel.get(String.valueOf(id));
        if (channel != null)
        {
            channel.writeAndFlush(byteBuf);
        } else
        {
            //说明此id对应的本地连接已断开
            byteBuf.release();
        }

    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause)
    {
        StackTraceElement[] stackTrace = cause.getStackTrace();
        for (StackTraceElement stackTraceElement : stackTrace)
        {
            System.out.println(stackTraceElement);
        }
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws InterruptedException
    {
        Map<String, Channel> idMapChannelOld = idMapChannel;
        idMapChannel = new ConcurrentHashMap<>();
        serverChannel = b.connect().sync().channel();
        System.out.println("本地服务与远程服务的channel断开");
        for (Map.Entry<String, Channel> entry : idMapChannelOld.entrySet())
        {
            entry.getValue().close();
        }
        idMapChannelOld.clear();
    }
}
