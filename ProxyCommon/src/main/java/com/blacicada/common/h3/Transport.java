package com.blacicada.common.h3;

import io.netty.channel.Channel;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.WriteBufferWaterMark;
import io.netty.channel.socket.nio.NioDatagramChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.quic.QuicCodecBuilder;
import io.netty.resolver.dns.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.concurrent.TimeUnit;

public final class Transport {
    public static final int MAX_HEADER_SIZE = 16384;
    public static final int MAX_PENDING_BYTES = 1024 * 1024;
    public static final WriteBufferWaterMark WATERMARK = new WriteBufferWaterMark(32768, 65536);
    private Transport() { }

    public static <B extends QuicCodecBuilder<B>> B limits(B builder, ProxyConfig config) {
        return builder.maxIdleTimeout(config.idleTimeoutSeconds(), TimeUnit.SECONDS)
                .initialMaxData(16 * 1024 * 1024)
                .initialMaxStreamDataBidirectionalLocal(256 * 1024)
                .initialMaxStreamDataBidirectionalRemote(256 * 1024)
                .initialMaxStreamsBidirectional(config.maxStreams());
    }

    public static DnsAddressResolverGroup resolver() {
        return new DnsAddressResolverGroup(new DnsNameResolverBuilder()
                .channelType(NioDatagramChannel.class).socketChannelType(NioSocketChannel.class)
                .nameServerProvider(DnsServerAddressStreamProviders.platformDefault()).queryTimeoutMillis(3000));
    }

    public static String authorization(String password) {
        return "Bearer " + Base64.getEncoder().encodeToString(password.getBytes(StandardCharsets.UTF_8));
    }

    public static boolean authorized(String expected, CharSequence actual) {
        return actual != null && MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8),
                actual.toString().getBytes(StandardCharsets.UTF_8));
    }

    /** 异常取消时重置双向流，不等待已经无法完成的传输。 */
    public static void abort(Channel channel) {
        if (channel instanceof io.netty.handler.codec.quic.QuicStreamChannel stream && stream.isActive()) {
            stream.shutdown((int) io.netty.handler.codec.http3.Http3ErrorCode.H3_REQUEST_CANCELLED.code())
                    .addListener(ignored -> stream.close());
        } else channel.close();
    }

    public static io.netty.channel.ChannelFuture shutdownOutput(Channel channel) {
        if (channel instanceof io.netty.channel.socket.DuplexChannel duplex) return duplex.shutdownOutput();
        if (channel instanceof io.netty.handler.codec.http2.Http2StreamChannel)
            return channel.writeAndFlush(com.blacicada.common.h2.H2DataCodec.Signal.FIN);
        return channel.close();
    }

    public static boolean isInputShutdown(Channel channel) {
        if (channel instanceof io.netty.channel.socket.DuplexChannel duplex) return duplex.isInputShutdown();
        return Boolean.TRUE.equals(channel.attr(com.blacicada.common.h2.H2DataCodec.INPUT_CLOSED).get());
    }

    public static void closeAfterWrites(Channel channel) {
        if (channel.isActive()) channel.writeAndFlush(io.netty.buffer.Unpooled.EMPTY_BUFFER)
                .addListener(ChannelFutureListener.CLOSE);
        else channel.close();
    }
}
