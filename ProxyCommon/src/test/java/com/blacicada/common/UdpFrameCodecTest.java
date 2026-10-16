package com.blacicada.common;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.channel.socket.ChannelInputShutdownEvent;
import io.netty.handler.codec.CorruptedFrameException;
import io.netty.handler.timeout.IdleStateEvent;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class UdpFrameCodecTest {
    @Test
    void fragmentedAndCoalescedPacketsKeepBoundaries() {
        var channel = new EmbeddedChannel(new UdpFrameCodec());
        try {
            assertFalse(channel.writeInbound(Unpooled.wrappedBuffer(new byte[]{0})));
            assertFalse(channel.writeInbound(Unpooled.wrappedBuffer(new byte[]{3, 1})));
            assertTrue(channel.writeInbound(Unpooled.wrappedBuffer(new byte[]{2, 3, 0, 0, 0, 1, 9})));
            for (byte[] expected : List.of(new byte[]{1, 2, 3}, new byte[0], new byte[]{9})) {
                ByteBuf packet = channel.readInbound();
                try {
                    byte[] actual = new byte[packet.readableBytes()];
                    packet.readBytes(actual);
                    assertArrayEquals(expected, actual);
                } finally {
                    packet.release();
                }
            }
            assertNull(channel.readInbound());
        } finally {
            channel.finishAndReleaseAll();
        }
    }

    @Test
    void encoderUsesReadableSliceAndPreservesEmptyPacket() {
        var channel = new EmbeddedChannel(new UdpFrameCodec());
        try {
            var packet = Unpooled.wrappedBuffer(new byte[]{99, 1, 2});
            packet.skipBytes(1);
            channel.writeOutbound(packet, Unpooled.EMPTY_BUFFER);
            for (byte[] expected : List.of(new byte[]{0, 2, 1, 2}, new byte[]{0, 0})) {
                ByteBuf frame = channel.readOutbound();
                try {
                    byte[] actual = new byte[frame.readableBytes()];
                    frame.readBytes(actual);
                    assertArrayEquals(expected, actual);
                } finally {
                    frame.release();
                }
            }
        } finally {
            channel.finishAndReleaseAll();
        }
    }

    @Test
    void rejectsOversizedAndTruncatedPackets() {
        var oversized = new EmbeddedChannel(new UdpFrameCodec());
        try {
            assertThrows(CorruptedFrameException.class, () -> oversized.writeInbound(Unpooled.buffer(2).writeShort(65508)));
        } finally {
            oversized.pipeline().remove(UdpFrameCodec.class);
            oversized.finishAndReleaseAll();
        }
        for (byte[] bytes : List.of(new byte[]{0}, new byte[]{0, 2, 1})) {
            var truncated = new EmbeddedChannel(new UdpFrameCodec());
            truncated.writeInbound(Unpooled.wrappedBuffer(bytes));
            assertThrows(CorruptedFrameException.class, truncated::finish);
            truncated.finishAndReleaseAll();
        }
    }

    @Test
    void transportHeaderMustBeUniqueAndKnown() {
        assertFalse(UdpTunnel.requested(List.of()));
        assertTrue(UdpTunnel.requested(List.of("udp")));
        for (var values : List.of(List.of("tcp"), List.of("UDP"), List.of("udp", "udp"), List.of("")))
            assertThrows(IllegalArgumentException.class, () -> UdpTunnel.requested(values));
    }

    @Test
    void eofAndIdleCloseAssociationWithoutSendingExtraPacket() {
        for (Object event : List.of(ChannelInputShutdownEvent.INSTANCE, IdleStateEvent.ALL_IDLE_STATE_EVENT)) {
            var peer = new EmbeddedChannel();
            var stream = new EmbeddedChannel(new UdpFrameCodec(), UdpTunnel.relay(peer));
            stream.pipeline().fireUserEventTriggered(event);
            assertFalse(stream.isActive());
            assertFalse(peer.isActive());
            assertNull(peer.readOutbound());
            stream.finishAndReleaseAll();
            peer.finishAndReleaseAll();
        }
    }
}
