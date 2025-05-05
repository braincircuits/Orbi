package com.blacicada.handler;

import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;

import java.util.Map;

public class ProxyServerInit extends ChannelInitializer<Channel> {
    private final Channel channel;
    private final int id;
    private Map<String,Channel> idMapChannel;
    public ProxyServerInit(int id, Channel channel, Map<String, Channel> idMapChannel) {
        this.id=id;
        this.channel=channel;
        this.idMapChannel=idMapChannel;
    }

    @Override
    protected void initChannel(Channel ch) throws Exception {
        ChannelPipeline pipeline = ch.pipeline();
        pipeline.addLast(new ProxyServerHandler(id,channel,idMapChannel));
    }
}
