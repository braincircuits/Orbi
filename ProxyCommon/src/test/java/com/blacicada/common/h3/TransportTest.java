package com.blacicada.common.h3;

import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.http3.Http3DataFrame;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class TransportTest {
    @Test void onlyReadableBytesBecomeDataAndReferencesAreReleased() {
        var channel = new EmbeddedChannel(new H3DataCodec());
        var input = Unpooled.copiedBuffer("discard:payload", StandardCharsets.US_ASCII);
        input.skipBytes(8);
        channel.writeOutbound(input);
        Http3DataFrame frame = channel.readOutbound();
        assertEquals(0, frame.content().readerIndex());
        assertEquals("payload", frame.content().toString(StandardCharsets.US_ASCII));
        frame.release(); assertEquals(0, input.refCnt()); channel.finishAndReleaseAll();
    }
    @Test void retryTokensRejectTamperingOtherAddressesAndExpiration() {
        var clock = new AtomicLong(1000);
        var handler = new RetryTokenHandler(clock::get);
        var sender = new InetSocketAddress("127.0.0.1", 4321);
        var token = Unpooled.buffer(); var id = Unpooled.wrappedBuffer(new byte[]{1,2,3,4});
        try {
            handler.writeToken(token, id, sender);
            int offset = handler.validateToken(token, sender);
            assertTrue(offset > 0);
            assertEquals(id, token.slice(offset, 4));
            assertEquals(-1, handler.validateToken(token, new InetSocketAddress("127.0.0.2", 4321)));
            assertEquals(-1, handler.validateToken(token, new InetSocketAddress("127.0.0.1", 4322)));
            token.setByte(token.writerIndex() - 1, 5);
            assertEquals(-1, handler.validateToken(token, sender));
            token.setByte(token.writerIndex() - 1, 4);
            clock.set(1121); assertEquals(-1, handler.validateToken(token, sender));
            clock.set(999); assertEquals(-1, handler.validateToken(token, sender));
        } finally { token.release(); id.release(); }
    }
}
