package com.blacicada.common.h3;

import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.channel.socket.DuplexChannel;
import io.netty.util.ReferenceCountUtil;

/** 两端均手动读取；目标写入变慢时暂停源端读取。 */
public class RelayHandler extends ChannelInboundHandlerAdapter {
    protected final Channel peer;
    private int pendingWrites;
    private boolean inputClosed;
    private boolean outputShutdown;

    public RelayHandler(Channel peer) { this.peer = peer; }

    protected boolean canRead() { return true; }

    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (!peer.isActive()) {
            ReferenceCountUtil.release(msg);
            Transport.abort(ctx.channel());
            return;
        }
        pendingWrites++;
        peer.writeAndFlush(msg).addListener(f -> ctx.executor().execute(() -> {
            pendingWrites--;
            if (!f.isSuccess()) { Transport.abort(peer); Transport.abort(ctx.channel()); }
            else if (inputClosed) finishOutput();
            else if (pendingWrites == 0 && canRead() && peer.isWritable() && ctx.channel().isActive()) ctx.read();
        }));
    }

    @Override public void channelReadComplete(ChannelHandlerContext ctx) {
        if (!inputClosed && pendingWrites == 0 && canRead() && peer.isWritable()) ctx.read();
    }

    @Override public void channelWritabilityChanged(ChannelHandlerContext ctx) {
        if (ctx.channel().isWritable() && peer.isActive()) {
            peer.eventLoop().execute(() -> {
                RelayHandler relay = peer.pipeline().get(RelayHandler.class);
                if (relay != null && relay.canRead() && !relay.inputClosed && relay.pendingWrites == 0) peer.read();
            });
        }
        ctx.fireChannelWritabilityChanged();
    }

    @Override public void userEventTriggered(ChannelHandlerContext ctx, Object event) {
        if (event == ChannelInputShutdownEvent.INSTANCE) {
            inputClosed = true;
            finishOutput();
        }
        ctx.fireUserEventTriggered(event);
    }

    private void finishOutput() {
        if (!outputShutdown && pendingWrites == 0) {
            outputShutdown = true;
            Transport.shutdownOutput(peer).addListener(f -> {
                if (!f.isSuccess() || Transport.isInputShutdown(peer)) peer.close();
            });
        }
    }

    @Override public void channelInactive(ChannelHandlerContext ctx) {
        Transport.closeAfterWrites(peer);
        ctx.fireChannelInactive();
    }

    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        Transport.abort(peer);
        Transport.abort(ctx.channel());
    }
}
