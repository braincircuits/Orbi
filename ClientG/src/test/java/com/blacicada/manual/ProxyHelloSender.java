package com.blacicada.manual;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * 在 IDEA 中直接运行 main，通过本地 HTTP 代理向目标发送 hello world。
 */
public final class ProxyHelloSender {
    private static final String PROXY_HOST = "127.0.0.1";
    private static final int PROXY_PORT = 8080;
    // 此地址由代理服务端访问；服务端在远程机器时，应改为它能访问的接收端地址。
    private static final String TARGET_HOST = "127.0.0.1";
    private static final int TARGET_PORT = 18080;

    public static void main(String[] args) throws Exception {
        if (args.length != 0 && args.length != 4) {
            throw new IllegalArgumentException("参数：proxyHost proxyPort targetHost targetPort；不填则使用类顶部默认值");
        }
        String proxyHost = args.length == 0 ? PROXY_HOST : args[0];
        int proxyPort = args.length == 0 ? PROXY_PORT : Integer.parseInt(args[1]);
        String targetHost = args.length == 0 ? TARGET_HOST : args[2];
        int targetPort = args.length == 0 ? TARGET_PORT : Integer.parseInt(args[3]);
        if (targetHost.indexOf('\r') >= 0 || targetHost.indexOf('\n') >= 0 || targetPort < 1 || targetPort > 65535) {
            throw new IllegalArgumentException("目标地址或端口无效");
        }
        String authority = (targetHost.contains(":") && !targetHost.startsWith("[")
                ? "[" + targetHost + "]" : targetHost) + ":" + targetPort;
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(proxyHost, proxyPort), 10_000);
            socket.setSoTimeout(30_000);
            System.out.printf("已连接本地代理 %s:%d，申请 CONNECT %s%n", proxyHost, proxyPort, authority);
            var output = socket.getOutputStream();
            var input = socket.getInputStream();
            output.write(("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n\r\n")
                    .getBytes(StandardCharsets.US_ASCII));
            output.flush();

            String headers = readHeaders(input);
            String[] status = headers.substring(0, headers.indexOf("\r\n")).split(" +", 3);
            if (status.length < 2 || !status[1].matches("2[0-9]{2}")) {
                throw new IOException("CONNECT 未成功，停止发送");
            }

            byte[] message = "hello world".getBytes(StandardCharsets.UTF_8);
            output.write(message);
            output.flush();
            // 表示请求数据发送完毕，仍保留读取方向，等待目标回显。
            socket.shutdownOutput();
            System.out.println("已发送：hello world");
            byte[] reply = input.readNBytes(message.length);
            if (!Arrays.equals(message, reply)) {
                throw new IOException("回显内容不一致");
            }
            System.out.println("收到目标回显：" + new String(reply, StandardCharsets.UTF_8));
            System.out.println("代理通信测试成功");
        }
    }

    /**
     * 只读取到响应头末尾，避免吞掉隧道中的数据；同时限制头部大小。
     */
    private static String readHeaders(InputStream input) throws IOException {
        var bytes = new ByteArrayOutputStream();
        int tail = 0;
        while (bytes.size() < 16 * 1024) {
            int value = input.read();
            if (value == -1) throw new IOException("CONNECT 响应头尚未完整接收，连接已关闭");
            bytes.write(value);
            tail = (tail << 8) | value;
            if (tail == 0x0d0a0d0a) return bytes.toString(StandardCharsets.US_ASCII);
        }
        throw new IOException("CONNECT 响应头超过 16 KiB");
    }
}
