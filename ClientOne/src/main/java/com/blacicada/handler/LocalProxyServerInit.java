package com.blacicada.handler;

import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import static com.blacicada.OneClient.serverChannel;

public class LocalProxyServerInit extends ChannelInitializer<Channel>
{
    public static Map<String, Channel> idMapChannel = new ConcurrentHashMap<>();
    private final static AtomicInteger atomicInteger = new AtomicInteger();


    @Override
    protected void initChannel(Channel ch)
    {
        ChannelPipeline pipeline = ch.pipeline();
        int id = atomicInteger.incrementAndGet();
        if (id == 100 * 10000)
        {
            atomicInteger.set(0);
        }
        idMapChannel.put(String.valueOf(id), ch);
        pipeline.addLast(new LocalProxyServerHandler(id, serverChannel));
    }
}
