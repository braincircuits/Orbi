package com.blacicada;

import com.blacicada.common.init.ClientInit;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.handler.ProxyInitializer;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.UnpooledByteBufAllocator;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.socket.ServerSocketChannel;
import io.netty.channel.socket.SocketChannel;

import java.net.InetSocketAddress;

public class ClientApplication {
    // 远程服务器地址
    private static final InetSocketAddress serverSocketAddress = ClientInit.inetSocketAddress;
    //    private static final EntityManagerFactory emf = Persistence.createEntityManagerFactory("mysql");
//    public static final Mutiny.SessionFactory sessionFactory = emf.unwrap(Mutiny.SessionFactory.class);
    public static final EventLoopGroup group = NettyCommon.getGroup(1);
    public static final Class<SocketChannel> socketChannel = NettyCommon.getSocketChannel();
    public static final Class<ServerSocketChannel> serverSocketChannel = NettyCommon.getServerSocketChannel();

    public static void main(String[] args) {
        try {
            ServerBootstrap b = new ServerBootstrap();
            b.group(group)
                    .channel(serverSocketChannel)
                    .option(ChannelOption.SO_BACKLOG, 128)
                    // 非池化分配器
                    .option(ChannelOption.ALLOCATOR, UnpooledByteBufAllocator.DEFAULT)
                    .childHandler(new ProxyInitializer(serverSocketAddress))
                    .childOption(ChannelOption.SO_KEEPALIVE, true)
                    .bind(ClientInit.port).sync();
        } catch (Exception e) {
            group.shutdownGracefully();
        }

    }
}
