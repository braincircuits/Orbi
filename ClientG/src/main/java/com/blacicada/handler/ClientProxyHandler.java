package com.blacicada.handler;

import com.blacicada.common.codec.MapDecoder;
import com.blacicada.common.codec.MapEncoder;
import com.blacicada.common.data.StaticValue;
import com.blacicada.common.init.ClientInit;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.common.util.url.Host;
import com.blacicada.common.util.url.URLUtil;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.internal.ThreadLocalRandom;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

import static com.blacicada.ClientApplication.socketChannel;
import static com.blacicada.common.Constant.seqKey;

public class ClientProxyHandler extends ChannelInboundHandlerAdapter
{

    private InetSocketAddress inetSocketAddress;
    private Channel outboundChannel;
    private static final byte[] password = ClientInit.password;
    private final static Logger logger = LogManager.getLogger(ClientProxyHandler.class);


    public ClientProxyHandler(InetSocketAddress inetSocketAddress)
    {
        this.inetSocketAddress = inetSocketAddress;
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf = (ByteBuf) msg;
//        int byteBufLength = byteBuf.readableBytes();
//        sessionFactory.withTransaction(session -> {
//            Length length = new Length();
//            length.setLength(byteBufLength);
//            return session.persist(length);
//        }).subscribe().with(unused -> {});
        if (outboundChannel == null)
        {
            Channel channel = ctx.channel();
            channel.config().setAutoRead(false);
            // 随机
            int seq = ThreadLocalRandom.current().nextInt(0, MapDecoder.num);
            Host host = URLUtil.parseUrl(byteBuf);
//            sessionFactory.withTransaction(session -> {
//                URLHistory urlHistory = new URLHistory();
//                urlHistory.setUrl(host.url()+host.port());
//                return session.persist(urlHistory);
//            }).subscribe().with(o -> {});
            final boolean s = ClientUtil.urlMatch(host.url());
            if (s)
            {
                inetSocketAddress = new InetSocketAddress(host.url(), host.port());
            }
            final Channel inboundChannel = channel;
            Bootstrap b = new Bootstrap();
            b.group(inboundChannel.eventLoop())
                    .channel(socketChannel)
                    .option(ChannelOption.SO_KEEPALIVE, true)
                    .handler(new ChannelInitializer<>()
                    {
                        @Override
                        protected void initChannel(Channel ch) throws Exception
                        {
                            ChannelPipeline pipeline = ch.pipeline();
                            if (!s)
                            {
                                pipeline.addLast(new SeqSendHandler());
                                pipeline.addLast(new MapDecoder(seq));
                                pipeline.addLast(new MapEncoder(seq));
                            }
                            pipeline.addLast(new ProxyBackendHandler(inboundChannel));
                        }
                    })
            ;
            b.connect(inetSocketAddress).addListener((ChannelFutureListener) future -> {
                outboundChannel=future.channel();
                if (!future.isSuccess())
                {
                    inboundChannel.close();
                    ReferenceCountUtil.release(msg);
                    logger.error("连接代理服务器失败" + inetSocketAddress);
                } else
                {
                    inboundChannel.config().setAutoRead(true);
                    if (!s)
                    {
                        // 设置seq
                        outboundChannel.attr(seqKey).set(seq);
                        outboundChannel.write(Unpooled.wrappedBuffer(password));
                        outboundChannel.writeAndFlush(msg);

                    } else
                    {
                        if (host.https())
                        {
                            ReferenceCountUtil.release(msg);
                            inboundChannel.writeAndFlush(Unpooled.copiedBuffer(StaticValue.connectResponse, StandardCharsets.UTF_8)).addListener(new ChannelFutureListener() {
                                @Override
                                public void operationComplete(ChannelFuture future) throws Exception {
                                    inboundChannel.config().setAutoRead(true);
                                }
                            });
                        } else
                        {
                            outboundChannel.writeAndFlush(msg).addListener(new ChannelFutureListener()
                            {
                                @Override
                                public void operationComplete(ChannelFuture future) throws Exception
                                {
                                    inboundChannel.config().setAutoRead(true);
                                    if (!future.isSuccess())
                                    {
                                        logger.info("写入代理channel失败 活动:" + outboundChannel.isActive() + "open" + outboundChannel.isOpen() + "引用:" + byteBuf.refCnt());
                                        future.channel().close();
                                    }
                                }
                            });
                        }
                    }
                }
            });
        } else if (outboundChannel.isActive())
        {
            outboundChannel.writeAndFlush(msg);
        } else
        {
            ReferenceCountUtil.release(msg);
            logger.info("代理channel断开" + byteBuf.refCnt());
        }
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception
    {
        if (outboundChannel != null)
        {
            NettyCommon.closeChannel(outboundChannel);
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception
    {
        logger.info(cause.getMessage());
        StackTraceElement[] stackTrace = cause.getStackTrace();
        for (StackTraceElement stackTraceElement : stackTrace)
        {
            logger.info(stackTraceElement);
        }
        NettyCommon.closeChannel(ctx.channel());
    }

}
