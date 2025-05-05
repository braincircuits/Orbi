package com.blacicada.handler;

import com.blacicada.common.codec.MapDecoder;
import com.blacicada.common.codec.MapEncoder;
import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;
import io.netty.handler.codec.LengthFieldBasedFrameDecoder;
import io.netty.handler.codec.LengthFieldPrepender;

import java.nio.ByteOrder;

public class OneServerHandlerInit extends ChannelInitializer<Channel> {
    @Override
    protected void initChannel(Channel ch) {
        ChannelPipeline pipeline = ch.pipeline();
        pipeline.addLast(new LengthFieldBasedFrameDecoder(ByteOrder.BIG_ENDIAN, 100000, 0, 4, 0, 4, true));
        pipeline.addLast(new LengthFieldPrepender(ByteOrder.BIG_ENDIAN,4,0,false));
        pipeline.addLast(new MapEncoder());
        pipeline.addLast(new MapDecoder());
        pipeline.addLast(new OneServerHandler());
    }
}
