package com.blacicada;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

public class SoketA {
    private static byte flag = 0;
    static Socket accept;

    public static void main(String[] args) throws IOException, InterruptedException {
        ServerSocket serverSocket = new ServerSocket(1080);
        accept = serverSocket.accept();
        InputStream serverInput = null;
        serverInput = accept.getInputStream();
        OutputStream serverOutput = accept.getOutputStream();
        Socket client = connect(serverInput, serverOutput);
        OutputStream clientOutput = client.getOutputStream();
        InputStream clientInput = client.getInputStream();
        switch (flag) {
            case 1:
                http(serverInput, serverOutput, clientInput, clientOutput);
                break;
            case 2:
                https(serverInput, serverOutput, clientInput, clientOutput);
                break;

        }
    }

    public static void http(InputStream serverInput, OutputStream serverOutput,
                            InputStream clientInput, OutputStream clientOutput) throws IOException, InterruptedException {
        while (true) {
            leaf(clientInput, serverOutput);
            leaf(serverInput, clientOutput);
        }
    }

    public static void https(InputStream serverInput, OutputStream serverOutput,
                            InputStream clientInput, OutputStream clientOutput) throws IOException, InterruptedException {
        while (true) {
            leaf(serverInput, clientOutput);
            /*为什么要睡眠才行，不睡眠不行吗*/
            TimeUnit.MILLISECONDS.sleep(500);
            leaf(clientInput, serverOutput);
            TimeUnit.MILLISECONDS.sleep(500);
        }
    }

    public static boolean leaf(InputStream inputStream, OutputStream outputStream) throws IOException, InterruptedException {
        byte[] bytes = new byte[102400];
        int read = inputStream.read(bytes);
        System.out.println(new String(bytes,0,read));
        outputStream.write(bytes, 0, read);
        outputStream.flush();
        return false;
    }


    public static Socket connect(InputStream inputStream, OutputStream outputStream) throws IOException {
        byte[] bytes = new byte[10240];
        int read = inputStream.read(bytes);
        if (bytes[0] == 67) {
            flag=2;
            String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
            outputStream.write(connectResponse.getBytes(StandardCharsets.UTF_8));
            outputStream.flush();
            Map<String, String> host = getHost(bytes);
            Socket client=null;
            try {
                System.out.println("开始连接：" + host.get("url"));
                client = new Socket(host.get("url"), Integer.valueOf(host.get("port")));
            } catch (Exception e) {
                System.out.println(host);
                System.out.println("错误" + new String(bytes, 0, read));
            }
            return client;
        }
        flag=1;
        Map<String, String> host = getHost(bytes);
        Socket client = null;
        try {
            System.out.println("开始连接：" + host.get("url"));
            client = new Socket(host.get("url"),Integer.valueOf(host.get("port")));
        }catch (Exception e) {
            System.out.println("连接错误"+host.get("url"));
            System.out.println(host);
            System.out.println(new String(bytes,0,read,StandardCharsets.US_ASCII));
        }
        OutputStream clientOutputStream = client.getOutputStream();
        clientOutputStream.write(bytes,0,read);
        clientOutputStream.flush();
        return client;
    }

    public static Map<String, String> getHost(byte[] bytes) {
        HashMap<String, String> host = new HashMap<>();
        int s = 0;
        int e = 0;
        int ps = 0;
        int pe = 0;
        for (int t = 0; t < bytes.length; t++) {
            if (bytes[t] == 13 && bytes[t + 1] == 10 && bytes[t + 2] == 72) {
                s = t + 8;
                t += 8;
            }
            if (e == 0 && bytes[t] == 13 && bytes[t + 1] == 10) {
                e=t;
                break;
            }
            if (s != 0 && bytes[t] == 58) {
                e = t;
            }
            if (e != 0 && bytes[t] == 13 && bytes[t + 1] == 10) {
                ps = e + 1;
                pe = t;
                break;
            }
        }
        if (pe == ps) {
            host.put("port", "80");
        } else {
            host.put("port", new String(bytes, ps, pe - ps));
        }
        host.put("url", new String(bytes, s, e - s));
        return host;
    }
}
