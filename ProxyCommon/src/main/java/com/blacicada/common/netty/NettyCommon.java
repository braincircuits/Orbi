package com.blacicada.common.netty;

import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollEventLoopGroup;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.epoll.EpollSocketChannel;
import io.netty.channel.kqueue.KQueue;
import io.netty.channel.kqueue.KQueueEventLoopGroup;
import io.netty.channel.kqueue.KQueueServerSocketChannel;
import io.netty.channel.kqueue.KQueueSocketChannel;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.ServerSocketChannel;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;


public class NettyCommon
{
    public static EventLoopGroup getGroup(int nThreads)
    {
        if (Epoll.isAvailable())
        {
            return new EpollEventLoopGroup(nThreads);
        } else if (KQueue.isAvailable())
        {
            return new KQueueEventLoopGroup(nThreads);
        }
        return new NioEventLoopGroup(nThreads);
    }

    // 使用默认线程数
    public static EventLoopGroup getGroup()
    {
        return getGroup(0);
    }

    @SuppressWarnings("unchecked")
    public static <T extends ServerSocketChannel> Class<T> getServerSocketChannel()
    {
        if (Epoll.isAvailable())
        {
            return (Class<T>) EpollServerSocketChannel.class;
        } else if (KQueue.isAvailable())
        {
            return (Class<T>) KQueueServerSocketChannel.class;
        }
        return (Class<T>) NioServerSocketChannel.class;
    }


    @SuppressWarnings("unchecked")
    public static <T extends SocketChannel> Class<T> getSocketChannel()
    {
        if (Epoll.isAvailable())
        {
            return (Class<T>) EpollSocketChannel.class;
        } else if (KQueue.isAvailable())
        {
            return (Class<T>) KQueueSocketChannel.class;
        }
        return (Class<T>) NioSocketChannel.class;
    }

    public static void closeChannel(Channel channel)
    {
        if (channel.isActive()) channel.close();
    }

    public static void closeOnFlush(Channel channel)
    {
        if (channel.isActive()) channel.writeAndFlush(Unpooled.EMPTY_BUFFER).addListener(ChannelFutureListener.CLOSE);
    }

}
