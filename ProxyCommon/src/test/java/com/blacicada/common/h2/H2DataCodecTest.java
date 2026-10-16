package com.blacicada.common.h2;

import com.blacicada.common.RelayHandler;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.http2.*;
import io.netty.util.ReferenceCountUtil;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;

import static org.junit.jupiter.api.Assertions.*;

class H2DataCodecTest {
    private static final class Reads extends ChannelOutboundHandlerAdapter {
        int count;

        @Override
        public void read(ChannelHandlerContext ctx) {
            count++;
            ctx.read();
        }
    }

    @Test
    void unknownFramesDoNotResumeReadingWhileBusinessWritesArePending() {
        var messages = new ArrayList<Object>();
        var promises = new ArrayList<ChannelPromise>();
        var peer = new EmbeddedChannel(new ChannelOutboundHandlerAdapter() {
            @Override
            public void write(ChannelHandlerContext ctx, Object message, ChannelPromise promise) {
                messages.add(message);
                promises.add(promise);
            }
        });
        var reads = new Reads();
        var source = new EmbeddedChannel(reads, new H2DataCodec(), new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            source.writeInbound(new DefaultHttp2DataFrame(Unpooled.wrappedBuffer(new byte[]{42})));
            int before = reads.count;
            assertFalse(promises.getFirst().isDone());
            for (int i = 0; i < 10; i++) {
                var frame = new DefaultHttp2UnknownFrame((byte) 0x40, new Http2Flags(), Unpooled.buffer(1).writeByte(i));
                source.writeInbound(frame);
                assertEquals(0, frame.refCnt(), "忽略未知帧仍需释放引用");
                assertTrue(source.isActive(), "未知扩展帧不能关闭业务隧道");
            }
            assertEquals(before, reads.count, "未知帧不能绕过待写业务数据的反压");
            promises.getFirst().setSuccess();
            assertEquals(before + 1, reads.count, "写入完成后由转发层恢复读取");
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
            messages.forEach(ReferenceCountUtil::release);
            promises.forEach(promise -> promise.trySuccess());
        }
    }

    @Test
    void unknownOnlyBatchResumesReadingAndAllowsFollowingData() {
        var peer = new EmbeddedChannel();
        var reads = new Reads();
        var source = new EmbeddedChannel(reads, new H2DataCodec(), new RelayHandler(peer));
        source.config().setAutoRead(false);
        try {
            int before = reads.count;
            var frame = new DefaultHttp2UnknownFrame((byte) 0x40, new Http2Flags(), Unpooled.buffer(1).writeByte(0));
            source.writeInbound(frame);
            assertEquals(0, frame.refCnt());
            assertTrue(source.isActive());
            assertEquals(before + 1, reads.count, "只有未知帧的读取轮次结束后仍应继续读取");
            source.writeInbound(new DefaultHttp2DataFrame(Unpooled.wrappedBuffer(new byte[]{42})));
            ByteBuf forwarded = peer.readOutbound();
            try {
                assertEquals(42, forwarded.readUnsignedByte());
            } finally {
                forwarded.release();
            }
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }

    @Test
    void unexpectedKnownFramesStillCloseTheTunnel() {
        var peer = new EmbeddedChannel();
        var source = new EmbeddedChannel(new H2DataCodec(), new RelayHandler(peer));
        try {
            source.writeInbound(new DefaultHttp2HeadersFrame(new DefaultHttp2Headers().status("200")));
            assertFalse(source.isActive(), "业务阶段不能接受额外的已知非 DATA 帧");
            assertFalse(peer.isActive());
        } finally {
            source.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }
}
