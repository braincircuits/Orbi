package com.blacicada.common.h3;

import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.channel.socket.DuplexChannel;
import io.netty.util.ReferenceCountUtil;

/** Both endpoints use manual reads. A slow destination naturally pauses its source. */
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
            ctx.close();
            return;
        }
        pendingWrites++;
        peer.writeAndFlush(msg).addListener(f -> ctx.executor().execute(() -> {
            pendingWrites--;
            if (!f.isSuccess()) { peer.close(); ctx.close(); }
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
        if (!outputShutdown && pendingWrites == 0 && peer instanceof DuplexChannel duplex) {
            outputShutdown = true;
            duplex.shutdownOutput().addListener(f -> {
                if (!f.isSuccess() || duplex.isInputShutdown()) peer.close();
            });
        }
    }

    @Override public void channelInactive(ChannelHandlerContext ctx) {
        Transport.closeAfterWrites(peer);
        ctx.fireChannelInactive();
    }

    @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        peer.close();
        ctx.close();
    }
}
