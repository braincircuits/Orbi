package com.blacicada;

import com.blacicada.common.init.ServerInit;
import com.blacicada.handler.ProxyServerInitializer;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import static com.blacicada.common.netty.NettyCommon.getGroup;
import static com.blacicada.common.netty.NettyCommon.getServerSocketChannel;

public class NettyServer {
    private final static Logger logger= LogManager.getLogger(NettyServer.class);
    public static void main(String[] args) throws InterruptedException {
        EventLoopGroup bossGroup = getGroup(2);
        ServerBootstrap bootstrap = new ServerBootstrap();
        bootstrap.group(bossGroup)
                .channel(getServerSocketChannel())
                .option(ChannelOption.SO_BACKLOG, 128)
                .childHandler(new ProxyServerInitializer())
                .childOption(ChannelOption.SO_KEEPALIVE,true)
        ;
        bootstrap.bind(ServerInit.port).addListener(future -> {
            logger.info("启动成功:"+future.isSuccess()+"=================");
        }).sync();
    }
}
