package com.blacicada.handler;

import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;

import java.net.InetSocketAddress;

public class ProxyInitializer extends ChannelInitializer {
    InetSocketAddress inetSocketAddress;
    public ProxyInitializer(InetSocketAddress inetSocketAddress) {
        this.inetSocketAddress=inetSocketAddress;
    }
    @Override
    protected void initChannel(Channel ch) throws Exception {
        ch.pipeline()
                .addLast(new ClientProxyHandler(inetSocketAddress));
    }
}
