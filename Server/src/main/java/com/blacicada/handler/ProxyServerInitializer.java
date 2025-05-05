package com.blacicada.handler;

import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;

public class ProxyServerInitializer extends ChannelInitializer {


    @Override
    protected void initChannel(Channel ch) throws Exception {
        System.out.println(Thread.currentThread().getName()+"  22");
        ChannelPipeline pipeline = ch.pipeline();
        pipeline.addLast(new SeqAcceptHandler());
    }
}
