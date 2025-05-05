package com.blacicada.handler;

import com.blacicada.common.util.url.Host;
import io.netty.buffer.ByteBuf;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.util.ReferenceCountUtil;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

public class ProxyServerResponseHandler extends ChannelInboundHandlerAdapter {
    private final static Logger logger=LogManager.getLogger(ProxyServerResponseHandler.class);
    Channel inboundChannel;
    Host host;
    ByteBuf b;
    public ProxyServerResponseHandler(Channel inboundChannel, Host host) {
        this.inboundChannel=inboundChannel;
        this.host=host;
    }
    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception {
        if (inboundChannel.isActive()) {
            inboundChannel.close();
        } else if (inboundChannel.isOpen()) {
            logger.error("in channel 不应该为打开");
        }
    }


    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        b=(ByteBuf) msg;
        if (inboundChannel.isActive()) {
            inboundChannel.writeAndFlush(msg);
        } else {
            ReferenceCountUtil.release(msg);
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception {
        logger.warn("out123"+cause.getMessage());
        if (cause.getMessage().contains("Cannot reserve")) {
            logger.error("内存泄露=================="+b.refCnt());
            StackTraceElement[] stackTrace = cause.getStackTrace();
            for (StackTraceElement stackTraceElement : stackTrace) {
                logger.error(stackTraceElement);
            }
        }
        ctx.close();
    }
}
