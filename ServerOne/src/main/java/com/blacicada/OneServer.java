package com.blacicada;

import com.blacicada.common.init.ServerInit;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.handler.OneServerHandlerInit;
import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoop;
import io.netty.channel.EventLoopGroup;

import static com.blacicada.common.netty.NettyCommon.getSocketChannel;

public class OneServer
{
    public final static EventLoopGroup workGroup = NettyCommon.getGroup(1);
    public final static Bootstrap bootstrap = new Bootstrap();
    public final static EventLoop singleEventLoop = workGroup.next();
    public static final ServerBootstrap serverBootstrap = new ServerBootstrap();

    public static void main(String[] args)
    {
        try
        {
            bootstrap.group(workGroup)
                    .channel(getSocketChannel())
                    .option(ChannelOption.SO_KEEPALIVE, true)
            ;
            serverBootstrap.group(workGroup)
                    .channel(NettyCommon.getServerSocketChannel())
                    .option(ChannelOption.SO_BACKLOG, 128)
                    .childHandler(new OneServerHandlerInit())
                    .childOption(ChannelOption.SO_KEEPALIVE, true)
            ;
            serverBootstrap.bind(ServerInit.port).sync().addListener(future -> {
            });
        } catch (Exception e)
        {
            workGroup.shutdownGracefully();
        }
    }
}
