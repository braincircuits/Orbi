package com.blacicada.handler;

import com.blacicada.OneServer;
import com.blacicada.common.data.StaticValue;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.common.util.url.Host;
import com.blacicada.common.util.url.URLUtil;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.AttributeKey;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class OneServerHandler extends ChannelInboundHandlerAdapter
{
    public final Map<String, Channel> idMapChannel = new ConcurrentHashMap<>();
    private final byte[] connectResponseBytes = StaticValue.connectResponse.getBytes(StandardCharsets.UTF_8);

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        int id = byteBuf.readInt();
        String channelId = String.valueOf(id);
        Channel targetChannel = idMapChannel.get(channelId);
        if (targetChannel != null)
        {
            // 后面没有数据了说明是客户端发送的关闭指令
            if (byteBuf.readableBytes() == 0)
            {
                byteBuf.release();
                Channel channel = idMapChannel.get(channelId);
                if (channel != null)
                {
                    channel.attr(AttributeKey.valueOf(String.valueOf(id))).set(true);
                    channel.close();
                }else
                {
                    System.out.println("不应该==1");
                } 
                System.out.println("服务端收到关闭通知"+id);
            } else
            {
                targetChannel.writeAndFlush(byteBuf);
            }
        } else
        {
            // 说明是新连接
            int i = byteBuf.readableBytes();
            if (i > 4)
            {
                byte[] bytes = new byte[i];
                byteBuf.getBytes(byteBuf.readerIndex(), bytes);
                Host host;
                try
                {
                    host = URLUtil.parseUrl(bytes);
                    System.out.println(host.url()+"  "+id+"  "+ System.currentTimeMillis());
                } catch (Exception e)
                {
                    byteBuf.release();
                    System.out.println("链接解析错误" + new String(bytes) + "//" + ctx.channel().remoteAddress());
                    ctx.channel().writeAndFlush(Unpooled.wrappedBuffer(Unpooled.copyInt(id), Unpooled.copyInt(1)));
                    return;
                }
                boolean https = host.https();
                
                OneServer.bootstrap.handler(new ProxyServerInit(id, ctx.channel(),idMapChannel));
                OneServer.bootstrap.connect(new InetSocketAddress(host.url(), host.port())).addListener((ChannelFutureListener) future -> {
                    if (future.isSuccess())
                    {
                        if (https)
                        {
                            byteBuf.release();
                            ctx.channel().writeAndFlush(Unpooled.wrappedBuffer(Unpooled.copyInt(id), Unpooled.wrappedBuffer(connectResponseBytes)));
                        } else
                        {
                            future.channel().writeAndFlush(byteBuf);
                        }
                        idMapChannel.put(String.valueOf(id), future.channel());
                    }else
                    {
                        System.out.println("连接目标服务器失败"+id+host.url());
                        Channel channel = future.channel();
                        NettyCommon.closeChannel(channel);
                    } 
                });
            } else
            {
                byteBuf.release();
                System.out.println("远程代理连接已关闭"+id+"  "+byteBuf.readableBytes());
            }
        }

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
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception
    {
        for (Map.Entry<String, Channel> entry : idMapChannel.entrySet())
        {
            NettyCommon.closeChannel(entry.getValue());
        }
    }
}
