package com.blacicada.handler;

import com.blacicada.common.data.StaticValue;
import com.blacicada.common.init.ServerInit;
import com.blacicada.common.netty.NettyCommon;
import com.blacicada.common.util.url.Host;
import com.blacicada.common.util.url.URLUtil;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.util.ReferenceCountUtil;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

import static com.blacicada.common.netty.NettyCommon.getSocketChannel;

public class ProxyClientRequestHandler extends ChannelInboundHandlerAdapter
{
    private Channel outboundChannel;
    private final static Logger logger = LogManager.getLogger(ProxyClientRequestHandler.class);
    public boolean status = true;
    int type = 0;

    @Override
    public void channelActive(ChannelHandlerContext ctx) throws Exception
    {
        // 防止无效连接不释放
        // 连接建立后若为校验密码则断开连接
        ctx.executor().schedule(() -> {
            if (status)
            {
                Channel channel = ctx.channel();
                NettyCommon.closeChannel(channel);
                logger.fatal("无效连接"+channel.remoteAddress());
                System.out.println("无效连接"+channel.remoteAddress());
            }
        }, 5, TimeUnit.SECONDS);
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception
    {
        if (outboundChannel != null && outboundChannel.isActive())
        {
            outboundChannel.close();
        }
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg)
    {
        ByteBuf byteBuf = (ByteBuf) msg;
        // 验证密码
        if (status)
        {
            byte[] password = ServerInit.password;
            if (byteBuf.readableBytes() >= password.length)
            {
                ByteBuf readPW = byteBuf.readBytes(password.length);
                byte[] bytes = new byte[password.length];
                readPW.getBytes(0, bytes);
                ReferenceCountUtil.release(readPW);
                if (!equals(password, bytes))
                {
                    logger.warn("不合法请求" + ctx.channel().remoteAddress());
                    ReferenceCountUtil.release(msg);
                    ctx.close();
                    return;
                } else
                {
                    status = false;
                    logger.info("连接成功" + ctx.channel().remoteAddress());
                }
            } else
            {
                logger.warn("不合法请求" + ctx.channel().remoteAddress());
                ReferenceCountUtil.release(msg);
                ctx.close();
                return;
            }
        }
        if (outboundChannel == null)
        {
            int readNum = byteBuf.readableBytes();
            byte[] bytes = new byte[readNum];
            byteBuf.getBytes(byteBuf.readerIndex(), bytes);
            final Host host;
            try
            {
                host = URLUtil.parseUrl(bytes);
            } catch (Exception e)
            {
                logger.error("链接解析错误" + new String(bytes) + "//" + ctx.channel().remoteAddress());
                ReferenceCountUtil.release(msg);
                ctx.close();
                return;
            }
            if (bytes[0] == 71)
            {
                type = 1;
            }
            ctx.channel().eventLoop().execute(() -> {
                Bootstrap bootstrap = new Bootstrap();
                bootstrap.group(ctx.channel().eventLoop())
                        .channel(getSocketChannel())
                        .option(ChannelOption.SO_KEEPALIVE, true)
                        .handler(new ProxyServerResponseHandler(ctx.channel(), host)
                        );
                ChannelFuture cf = bootstrap.connect(new InetSocketAddress(host.url(), host.port()));
                outboundChannel = cf.channel();
                cf.addListener((ChannelFutureListener) future -> {
                    if (!future.isSuccess())
                    {
                        int readNum1 = byteBuf.readableBytes();
                        byte[] bytes1 = new byte[readNum1];
                        byteBuf.getBytes(byteBuf.readerIndex(), bytes1);
                        ReferenceCountUtil.release(msg);
                        logger.warn("目标客户端连接失败" + host.url() + ":" + host.port() + "活动" + cf.channel().isActive() + "打开" + cf.channel().isOpen() + "引用:" + byteBuf.refCnt() + "\n" + new String(bytes1));
                        ctx.close();
                    } else
                    {
                        switch (type)
                        {
                            case 0:
                                ctx.channel().writeAndFlush(Unpooled.copiedBuffer(StaticValue.connectResponse, StandardCharsets.UTF_8));
                                ReferenceCountUtil.release(msg);
                                break;
                            case 1:
                                future.channel().writeAndFlush(byteBuf);
                                break;
                        }
                    }
                });
            });
        } else
        {
            if (outboundChannel.isActive())
            {
                outboundChannel.writeAndFlush(msg);
            } else
            {
                ReferenceCountUtil.release(msg);
            }
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause)
    {
        logger.fatal("异常" + cause.getMessage());
        StackTraceElement[] stackTrace = cause.getStackTrace();
        for (StackTraceElement stackTraceElement : stackTrace)
        {
            logger.fatal(stackTraceElement);
        }
        ctx.close();
    }

    public boolean equals(byte[] value, byte[] other)
    {
        for (int i = 0; i < value.length; i++)
        {
            if (value[i] != other[i])
            {
                return false;
            }
        }
        return true;
    }
}
