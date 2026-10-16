package com.blacicada.common;

import io.netty.channel.*;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.channel.socket.SocketChannel;
import io.netty.util.ReferenceCountUtil;

/** 按轮次读取并集中刷新；目标写入变慢时暂停源端读取。 */
public class RelayHandler extends ChannelInboundHandlerAdapter {
    protected final Channel peer;
    private int pendingWrites;
    private boolean inputClosed;
    private boolean outputShutdown;
    private boolean reading;

    public RelayHandler(Channel peer) { this.peer = peer; }

    protected boolean canRead() { return true; }

    @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
        if (!peer.isActive()) {
            ReferenceCountUtil.release(msg);
            Transport.abort(ctx.channel());
            return;
        }
        reading = true;
        pendingWrites++;
        peer.write(msg).addListener(f -> {
            if (ctx.executor().inEventLoop()) written(ctx, f.isSuccess());
            else ctx.executor().execute(() -> written(ctx, f.isSuccess()));
        });
        // 仅在当前读取轮次内继续取数据；高水位或请求体结束立即停止预取。
        // 跨 EventLoop 的写入尚未入队时无法立即看到水位，仍逐轮手动读取。
        // HTTP/2、QUIC 子流启读可能同步重入，仅真实 TCP 套接字使用轮内批读。
        ctx.channel().config().setAutoRead(ctx.channel() instanceof SocketChannel
                && ctx.channel().isActive() && !inputClosed && canRead()
                && peer.eventLoop().inEventLoop() && peer.isWritable());
    }

    @Override public void channelReadComplete(ChannelHandlerContext ctx) {
        ctx.channel().config().setAutoRead(false);
        // 保持 reading 到刷新结束，避免同步写完成在当前轮次里重复启动读取。
        peer.flush();
        reading = false;
        readNext(ctx);
    }

    private void written(ChannelHandlerContext ctx, boolean success) {
        pendingWrites--;
        if (!success) { Transport.abort(peer); Transport.abort(ctx.channel()); }
        else if (inputClosed) finishOutput();
        else readNext(ctx);
    }

    private void readNext(ChannelHandlerContext ctx) {
        if (!reading && !inputClosed && pendingWrites == 0 && canRead() && peer.isWritable()
                && ctx.channel().isActive()) ctx.read();
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
            ctx.channel().config().setAutoRead(false);
            peer.flush();
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
