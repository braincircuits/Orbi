package com.blacicada;

import com.blacicada.common.init.ClientInit;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.handler.LocalProxyServerInit;
import com.blacicada.handler.OneClientInit;
import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.*;

import java.net.InetSocketAddress;

public class OneClient
{
    // 远程服务器地址
    private static final InetSocketAddress serverSocketAddress = ClientInit.inetSocketAddress;
    public final static EventLoopGroup workGroup = NettyCommon.getGroup(1);

    public final static EventLoop singleEventLoop = workGroup.next();
    public final static Bootstrap b = new Bootstrap();
    public static Channel serverChannel;

    public static void main(String[] args)
    {
        try
        {
            // 远程代理服务器连接
            b.group(workGroup)
                    .channel(NettyCommon.getSocketChannel())
                    .option(ChannelOption.SO_KEEPALIVE, true)
                    .handler(new OneClientInit())
                    .remoteAddress(serverSocketAddress)
            ;
            ChannelFuture f = b.connect().sync();
            serverChannel = f.channel();
        } catch (InterruptedException e)
        {
            workGroup.shutdownGracefully();
            throw new RuntimeException(e);
        }

        // 本地代理服务器启动
        try
        {
            ServerBootstrap serverBootstrap = new ServerBootstrap();
            serverBootstrap.group(workGroup)
                    .channel(NettyCommon.getServerSocketChannel())
                    .option(ChannelOption.SO_BACKLOG, 128)
                    .childHandler(new LocalProxyServerInit())
                    .childOption(ChannelOption.SO_KEEPALIVE, true)
                    .bind(ClientInit.port).sync();
        } catch (Exception e)
        {
            workGroup.shutdownGracefully();
        }
    }
}
