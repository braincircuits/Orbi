package com.netty;

import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class ProxyTypeHandle extends ChannelInboundHandlerAdapter {
    int type = 0;
    ChannelFuture cf = null;

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception {
        System.out.println("本地代理断开");
        if (cf != null) {
            cf.channel().close();
        } else {
            System.out.println("99999");
        }
    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg)  {
        ByteBuf byteBuf = (ByteBuf) msg;
        if (cf == null) {
            int readNum = byteBuf.readableBytes();
            byte[] bytes = new byte[readNum];
            if (bytes[0] == 71) {
                type = 1;
            }
            byteBuf.getBytes(0, bytes);
            Host host = Util.parseUrl(bytes);
            System.out.println("连接" + host);
            ctx.channel().eventLoop().execute(() -> {
                Bootstrap bootstrap = new Bootstrap();
                bootstrap.group(ctx.channel().eventLoop())
                        .channel(NioSocketChannel.class)
                        .option(ChannelOption.SO_KEEPALIVE, true)
                        .handler(new ChannelInitializer<SocketChannel>() {
                            @Override
                            protected void initChannel(SocketChannel ch)  {
                                ch.pipeline().addLast(new ChannelInboundHandlerAdapter() {
                                    @Override
                                    public void channelInactive(ChannelHandlerContext ctxb) throws Exception {
                                        System.out.println("目标服务器断开");
                                        ctx.close();
                                        ctxb.close();
                                    }

                                    @Override
                                    public void channelActive(ChannelHandlerContext ctxb)  {
                                        switch (type) {
                                            case 0:
                                                ctx.channel().writeAndFlush(Unpooled.copiedBuffer(StaticValue.connectResponse, StandardCharsets.UTF_8));
                                                break;
                                            case 1:
                                                ctxb.writeAndFlush(byteBuf);
                                                break;
                                        }
                                    }

                                    @Override
                                    public void channelRead(ChannelHandlerContext ctxb, Object msg) {
                                        ctx.channel().writeAndFlush(msg);
                                    }
                                });
                            }
                        });
                cf = bootstrap.connect(new InetSocketAddress(host.url(), host.port()));
            });
        } else {
            try {
                cf.channel().writeAndFlush(msg);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        cause.printStackTrace();
        try {
            ctx.close();
            cf.channel().close();
        } catch (Exception e) {
            System.out.println("连接关闭错误");
        }
    }
}
