package com.blacicada.handler;

import com.blacicada.common.codec.MapDecoder;
import com.blacicada.common.codec.MapEncoder;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelPipeline;
import io.netty.util.ReferenceCountUtil;
import io.netty.util.concurrent.ScheduledFuture;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.util.concurrent.TimeUnit;

public class SeqAcceptHandler extends ChannelInboundHandlerAdapter
{
    private final static Logger logger = LogManager.getLogger(SeqAcceptHandler.class);
    @Override
    public void channelActive(ChannelHandlerContext ctx) throws Exception
    {
        System.out.println(Thread.currentThread().getName()+"  11");
        // 防止无效连接不释放
        // 连接建立后若为校验密码则断开连接
        ScheduledFuture<?> schedule = ctx.channel().eventLoop().schedule(() -> {
            System.out.println("无效连接" + ctx.isRemoved());
            ctx.channel().close();
        }, 5, TimeUnit.SECONDS);

    }

    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception
    {
        ByteBuf byteBuf= (ByteBuf) msg;
        int seq = byteBuf.readInt();
        int num = MapDecoder.num;
        if (seq > num)
        {
            ctx.close();
            return;
        }
        ChannelPipeline pipeline = ctx.pipeline();
        pipeline.addLast(new MapDecoder(seq));
        pipeline.addLast(new MapEncoder(seq));
        pipeline.addLast(new ProxyClientRequestHandler());
        pipeline.remove(this.getClass());
        if (byteBuf.readableBytes() == 0)
        {
            logger.fatal("提示=======");
            ReferenceCountUtil.release(msg);
            return;
        }
        super.channelRead(ctx, msg);
    }
}
