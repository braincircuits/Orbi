package com.blacicada.manual;

import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/**
 * 在 IDEA 中直接运行 main，充当被代理服务端连接的目标 TCP 服务。
 */
public final class ProxyHelloReceiver {
    private static final String BIND_HOST = "127.0.0.1";
    private static final int PORT = 18080;

    public static void main(String[] args) throws Exception {
        if (args.length != 0 && args.length != 2) {
            throw new IllegalArgumentException("参数：bindHost port；不填则监听 127.0.0.1:18080");
        }
        String bindHost = args.length == 0 ? BIND_HOST : args[0];
        int port = args.length == 0 ? PORT : Integer.parseInt(args[1]);
        try (ServerSocket listener = new ServerSocket()) {
            listener.setReuseAddress(true);
            listener.bind(new InetSocketAddress(bindHost, port));
            System.out.printf("目标接收端已监听 %s:%d，等待代理服务端连接；点击 IDEA Stop 停止%n",
                    bindHost, listener.getLocalPort());
            while (true) {
                Socket connection = listener.accept();
                Thread.startVirtualThread(() -> receive(connection));
            }
        }
    }

    private static void receive(Socket socket) {
        String peer = socket.getRemoteSocketAddress().toString();
        try (socket) {
            System.out.println("代理服务端已连接：" + peer);
            // 使用 UTF-8 Reader，正确处理字符跨 TCP 分片的情况。
            var input = new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8);
            var output = new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8);
            char[] buffer = new char[1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                System.out.printf("收到 [%s]：%d 个字符%n", peer, count);
                output.write(buffer, 0, count);
                output.flush();
            }
            System.out.println("数据接收完毕，关闭连接：" + peer);
        } catch (Exception e) {
            System.err.println("接收失败 [" + peer + "]：" + e);
        }
    }
}
