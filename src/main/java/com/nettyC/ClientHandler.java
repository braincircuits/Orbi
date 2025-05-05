package com.nettyC;

import io.netty.bootstrap.Bootstrap;
import io.netty.channel.*;
import io.netty.channel.socket.nio.NioSocketChannel;

import java.net.InetSocketAddress;
import java.util.concurrent.TimeUnit;

public class ClientHandler extends ChannelInboundHandlerAdapter {
    private Bootstrap bootstrap;
    ChannelFuture cf;
    @Override
    public void channelActive(ChannelHandlerContext ctx) throws Exception {
        System.out.println("连接建立");
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception {
        cf.channel().close();
        System.out.println("浏览器断开");
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
        if (bootstrap == null) {
            bootstrap = new Bootstrap();
            bootstrap.group(ctx.channel().eventLoop())
                    .channel(NioSocketChannel.class)
                    .option(ChannelOption.SO_KEEPALIVE, true)
                    .handler(new ChannelInitializer<>() {
                        @Override
                        protected void initChannel(Channel ch) throws Exception {
                            ch.pipeline().addLast("abc",new ChannelInboundHandlerAdapter() {
                                @Override
                                public void channelInactive(ChannelHandlerContext ctxb) throws Exception {
                                    System.out.println("服务端断开");
                                    ctx.close();
                                }

                                @Override
                                public void channelRead(ChannelHandlerContext ctxb, Object msg) throws Exception {
                                    ctx.channel().writeAndFlush(msg);
                                }
                            });
                        }
                    });
            ctx.channel().eventLoop().execute(() -> {
                try {
                    cf = bootstrap.connect(new InetSocketAddress("127.0.0.1", 8080)).addListener(future -> {
                        future.get(200, TimeUnit.MILLISECONDS);
                        if (future.isSuccess()) {
                            cf.channel().writeAndFlush(msg);
                        }
                    });
                } catch (Exception e) {
                    System.out.println(989);
                    e.printStackTrace();
                }

            });
        } else {
            cf.channel().writeAndFlush(msg);
        }

    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception {
        System.out.println("异常" + cause.getMessage());
        try {
            ctx.close();
            cf.channel().close();
        } catch (Exception e) {
            System.out.println("88888888888");
        }
    }
}
