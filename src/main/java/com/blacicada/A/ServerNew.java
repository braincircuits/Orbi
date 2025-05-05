package com.blacicada.A;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Set;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

public class ServerNew {
    private ThreadPoolExecutor threadPool;
    private Selector selector;
    private ServerSocketChannel serverSocketChannel;
    String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
    private int port = 1080;

    public ServerNew() {
        threadPool = new ThreadPoolExecutor(
                2,
                2,
                3,
                TimeUnit.SECONDS,
                new LinkedBlockingQueue<>(3),
                Executors.defaultThreadFactory(),
                new ThreadPoolExecutor.DiscardOldestPolicy()
        );
        try {
            selector = Selector.open();
            serverSocketChannel = ServerSocketChannel.open();
            serverSocketChannel.bind(new InetSocketAddress(port));
            serverSocketChannel.configureBlocking(false);
            serverSocketChannel.register(selector, SelectionKey.OP_ACCEPT);
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }
    public static void main(String[] args) throws IOException {
        new ServerNew().go();
    }

    public void go() throws IOException {
        while (true) {
            int select = selector.select(1000);
            if ( select> 0) {
                Set<SelectionKey> selectionKeys = selector.selectedKeys();
                System.out.println(selector.keys().size());
                Iterator<SelectionKey> iterator = selectionKeys.iterator();
                while (iterator.hasNext()) {
                    SelectionKey key = iterator.next();
                    iterator.remove();
                    if (key.isAcceptable()) {
                        ServerSocketChannel serverSocketChannel = (ServerSocketChannel) key.channel();
                        SocketChannel socketChannel = serverSocketChannel.accept();
                        if (socketChannel == null) {
                            System.out.println("========");
                        }
                        socketChannel.configureBlocking(false);
                        socketChannel.register(selector, SelectionKey.OP_READ);
                    }
                    if (key.isReadable()) {
                        try {
                            SocketChannel req = (SocketChannel) key.channel();
                            ByteBuffer byteBuffer = readDate(req);
                            byte[] array = byteBuffer.array();
                            Object attachment = key.attachment();
                            if (attachment == null) {
                                Host host = getHost(array);
                                SocketChannel clientChannel = SocketChannel.open();
                                AtomicReference<Thread> thread = new AtomicReference<>();
                                FutureTask<Integer> futureTask = new FutureTask<>(() -> {
                                    thread.set(Thread.currentThread());
                                    try {
                                        clientChannel.connect(new InetSocketAddress(host.url(), host.port()));
                                    } catch (IOException e) {
                                        System.out.println("连接失败" + e.getMessage() + host.url());
                                    }
                                    return 1;
                                });
                                threadPool.execute(futureTask);
                                try {
                                    futureTask.get(200, TimeUnit.MILLISECONDS);
                                } catch (InterruptedException | ExecutionException | TimeoutException e) {
                                    thread.get().interrupt();
                                    //System.out.println("超时连接"+host.get("url"));
                                }
                                if (array[0] == 67) {
                                    req.write(ByteBuffer.wrap(connectResponse.getBytes(StandardCharsets.UTF_8)));
                                } else {
                                    System.out.println(".............0");
                                }
                                if (!clientChannel.isConnected()) {
                                    throw new RuntimeException("连接目标失败");
                                }
                                key.attach(clientChannel);
                                clientChannel.configureBlocking(false);
                                clientChannel.register(selector, SelectionKey.OP_READ, req);
                            } else {
                                SocketChannel res= (SocketChannel) attachment;
                                res.write(byteBuffer.flip());
                            }
                        } catch (Exception e) {
                            e.printStackTrace();
                            key.cancel();
                            SocketChannel req = (SocketChannel) key.channel();
                            req.close();
                            Object attachment = key.attachment();
                            if (attachment != null) {
                                SocketChannel socketChannel= (SocketChannel) attachment;
                                socketChannel.close();
                            }
                        }
                    }
                }
            }
        }
    }

    public ByteBuffer readDate(SocketChannel channel) throws IOException {
        ArrayList<ByteBuffer> datas = new ArrayList<>(10);
        int sum = 0;
        ByteBuffer buffer = null;
        do {
            int readNum=0;
            ByteBuffer allocate = ByteBuffer.allocate(1024);
            readNum = channel.read(allocate);
            if (readNum == -1) {
                throw new RuntimeException("-1");
            }
            if (readNum < 1024) {
                sum+=readNum;
                buffer = ByteBuffer.allocate(sum);
                for (ByteBuffer byteBuffer : datas) {
                    buffer.put(byteBuffer.flip());
                }
                buffer.put(allocate.flip());
                break;
            }
            sum+=readNum;
            datas.add(allocate);
        } while (true);
        return buffer;
    }

    public Host getHost(byte[] bytes) {
        Host host=null;
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
                e = t;
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
            host=new Host(new String(bytes, s, e - s),80);
        } else {
            host=new Host(new String(bytes, s, e - s),Integer.parseInt(new String(bytes, ps, pe - ps)));
        }
        System.out.println("请求地址：" + host.url());
        return host;
    }
}
