package com.blacicada.proxy;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.handler.codec.dns.DefaultDnsRecordDecoder;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** 只提取查询、TTL 和地址关联，转发时保留原始报文及未知记录。 */
final class DnsMessage {
    record Question(String name, int type, int dnsClass, int end) {}
    record Record(String name, int type, int dnsClass, long ttl, int ttlOffset, String value) {}
    final int id, flags;
    final Question question;
    final List<Record> answers = new ArrayList<>(), records = new ArrayList<>();
    final int additional;

    DnsMessage(byte[] bytes, boolean response) {
        ByteBuf input = Unpooled.wrappedBuffer(bytes);
        try {
            if (bytes.length < 12) throw new IllegalArgumentException("DNS 报文头不完整");
            id = input.readUnsignedShort(); flags = input.readUnsignedShort();
            int questions = input.readUnsignedShort(), answerCount = input.readUnsignedShort();
            int authorityCount = input.readUnsignedShort(); additional = input.readUnsignedShort();
            if (((flags & 0x8000) != 0) != response || (flags & 0x7800) != 0 || questions != 1)
                throw new IllegalArgumentException("仅支持包含一个问题的标准 DNS 查询");
            String name = name(input);
            question = new Question(name, input.readUnsignedShort(), input.readUnsignedShort(), input.readerIndex());
            if (response && (flags & 0x0200) != 0) return;
            if (!response && (answerCount != 0 || authorityCount != 0)) throw new IllegalArgumentException("DNS 查询区段无效");
            for (int section = 0; section < 3; section++) {
                int count = section == 0 ? answerCount : section == 1 ? authorityCount : additional;
                for (int i = 0; i < count; i++) {
                    String owner = name(input);
                    int type = input.readUnsignedShort(), dnsClass = input.readUnsignedShort();
                    int ttlOffset = input.readerIndex(); long ttl = input.readUnsignedInt();
                    int length = input.readUnsignedShort(), offset = input.readerIndex();
                    if (length > input.readableBytes()) throw new IllegalArgumentException("DNS 记录不完整");
                    String value = null;
                    if (type == 1 && length == 4 || type == 28 && length == 16) {
                        byte[] address = new byte[length]; input.getBytes(offset, address);
                        value = InetAddress.getByAddress(address).getHostAddress();
                    } else if (type == 5) {
                        ByteBuf cname = input.duplicate().writerIndex(offset + length);
                        value = name(cname);
                        if (cname.readerIndex() != offset + length) throw new IllegalArgumentException("DNS 别名记录无效");
                    }
                    input.readerIndex(offset + length);
                    var record = new Record(owner, type, dnsClass, ttl, ttlOffset, value);
                    records.add(record); if (section == 0) answers.add(record);
                }
            }
            if (input.isReadable()) throw new IllegalArgumentException("DNS 报文包含多余数据");
        } catch (java.net.UnknownHostException | IndexOutOfBoundsException e) {
            throw new IllegalArgumentException("DNS 报文无效", e);
        } finally { input.release(); }
    }

    private static String name(ByteBuf input) {
        String name = DefaultDnsRecordDecoder.decodeName(input).toLowerCase(Locale.ROOT);
        return name.endsWith(".") ? name.substring(0, name.length() - 1) : name;
    }
    boolean matches(DnsMessage query) {
        return id == query.id && question.name.equals(query.question.name)
                && question.type == query.question.type && question.dnsClass == query.question.dnsClass;
    }
    boolean successful() {
        return (flags & 0x020f) == 0 && records.stream().noneMatch(r -> r.type == 41 && (r.ttl >>> 24) != 0);
    }
    boolean cacheable() { return successful() && !answers.isEmpty() && records.stream().noneMatch(r -> r.type == 250 || r.type == 24); }

    /** 只信任当前问题及其 CNAME 链的回答，不能用无关附加记录建立关联。 */
    Map<String, Long> addresses() {
        var result = new HashMap<String, Long>();
        if (!successful() || question.dnsClass != 1 || question.type != 1 && question.type != 28) return result;
        String current = question.name;
        long chainTtl = 0xffffffffL;
        var visited = new java.util.HashSet<String>();
        while (visited.add(current)) {
            String owner = current;
            for (Record record : answers) {
                if (record.dnsClass == 1 && record.name.equals(owner) && record.type == question.type && record.value != null)
                    result.merge(record.value, Math.min(chainTtl, record.ttl), Math::min);
            }
            Record alias = answers.stream().filter(r -> r.dnsClass == 1 && r.type == 5 && r.name.equals(owner)).findFirst().orElse(null);
            if (alias == null || alias.value == null) break;
            current = alias.value; chainTtl = Math.min(chainTtl, alias.ttl);
        }
        return result;
    }

    static byte[] failure(byte[] query, int code) {
        ByteBuf output = Unpooled.buffer();
        try {
            int id = query.length >= 2 ? (query[0] & 255) << 8 | query[1] & 255 : 0;
            int flags = query.length >= 4 ? ((query[2] & 255) << 8 | query[3] & 255) & 0x0110 : 0;
            output.writeShort(id).writeShort(0x8080 | flags | code);
            output.writeShort(0).writeShort(0).writeShort(0).writeShort(0);
            try {
                var message = new DnsMessage(query, false);
                var q = message.question;
                io.netty.handler.codec.dns.DnsRecordEncoder.DEFAULT.encodeQuestion(
                        new io.netty.handler.codec.dns.DefaultDnsQuestion(q.name,
                                io.netty.handler.codec.dns.DnsRecordType.valueOf(q.type), q.dnsClass), output);
                output.setShort(4, 1);
            } catch (Exception ignored) {
                // 无效问题不能复制到错误响应中。
                output.writerIndex(12);
            }
            byte[] reply = new byte[output.readableBytes()]; output.readBytes(reply); return reply;
        } finally { output.release(); }
    }
}
