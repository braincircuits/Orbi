package com.blacicada.common.h3;

import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.quic.Quic;
import io.netty.handler.codec.quic.QuicTokenHandler;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.function.LongSupplier;

/** Short-lived, authenticated QUIC Retry tokens bound to the sender's IP and UDP port. */
public final class RetryTokenHandler implements QuicTokenHandler {
    private static final int PREFIX = 1 + Long.BYTES;
    private static final int OFFSET = PREFIX + 32;
    private final SecretKeySpec key;
    private final LongSupplier seconds;

    public RetryTokenHandler() { this(() -> System.currentTimeMillis() / 1000); }
    RetryTokenHandler(LongSupplier seconds) {
        byte[] secret = new byte[32]; new SecureRandom().nextBytes(secret);
        key = new SecretKeySpec(secret, "HmacSHA256"); this.seconds = seconds;
    }
    @Override public boolean writeToken(ByteBuf out, ByteBuf dcid, InetSocketAddress address) {
        byte[] id = new byte[dcid.readableBytes()]; dcid.getBytes(dcid.readerIndex(), id);
        long issued = seconds.getAsLong();
        out.writeByte(1).writeLong(issued).writeBytes(tag(issued, id, address)).writeBytes(id);
        return true;
    }
    @Override public int validateToken(ByteBuf token, InetSocketAddress address) {
        int size = token.readableBytes(), start = token.readerIndex();
        if (size < OFFSET || size > maxTokenLength() || token.getByte(start) != 1) return -1;
        long issued = token.getLong(start + 1), now = seconds.getAsLong();
        if (issued > now || now - issued > 120) return -1;
        byte[] actual = new byte[32], id = new byte[size - OFFSET];
        token.getBytes(start + PREFIX, actual); token.getBytes(start + OFFSET, id);
        return MessageDigest.isEqual(actual, tag(issued, id, address)) ? OFFSET : -1;
    }
    private byte[] tag(long issued, byte[] id, InetSocketAddress address) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256"); mac.init(key);
            mac.update((byte) 1);
            mac.update(ByteBuffer.allocate(8).putLong(issued).array());
            mac.update(address.getAddress().getAddress());
            mac.update(ByteBuffer.allocate(4).putInt(address.getPort()).array());
            return mac.doFinal(id);
        } catch (GeneralSecurityException e) { throw new IllegalStateException("HMAC-SHA256 unavailable", e); }
    }
    @Override public int maxTokenLength() { return OFFSET + Quic.MAX_CONN_ID_LEN; }
}
