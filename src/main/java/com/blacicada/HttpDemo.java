package com.blacicada;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

public class HttpDemo {
    public static void main(String[] args) throws IOException {
        String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
        ServerSocket serverSocket = new ServerSocket(1080);
        Socket accept = serverSocket.accept();
        InputStream inputStream = accept.getInputStream();
        OutputStream outputStream = accept.getOutputStream();
        byte[] bytes = new byte[102400];
        int read = inputStream.read(bytes);
        System.out.println(new String(bytes,0,read,StandardCharsets.ISO_8859_1));
        outputStream.write(connectResponse.getBytes(StandardCharsets.UTF_8));
        read = inputStream.read(bytes);
        System.out.println(new String(bytes,0,read));
    }
}
