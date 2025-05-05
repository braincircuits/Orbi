package com.blacicada;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

public class NioServerA {
    private static final ReentrantLock LOCK = new ReentrantLock();
    private static final Condition STOP = LOCK.newCondition();
    private Selector selector;
    private Selector selectorRead;
    private ServerSocketChannel serverSocketChannel;
    private int port = 8080;
    ThreadPoolExecutor threadPool;


    public NioServerA() {
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
            selectorRead = Selector.open();
            serverSocketChannel = ServerSocketChannel.open();
            serverSocketChannel.bind(new InetSocketAddress(port));
            serverSocketChannel.configureBlocking(false);
            serverSocketChannel.register(selector, SelectionKey.OP_ACCEPT);
        } catch (IOException e) {
            e.printStackTrace();
        }

    }

    public void accept() {
        while (true) {
            int action = 0;
            try {
                action = selector.select(3000);
            } catch (IOException e) {
                e.printStackTrace();
            }
            if (action > 0) {
                System.out.println("收到连接");
                Set<SelectionKey> selectionKeys = selector.selectedKeys();
                Iterator<SelectionKey> iterator = selectionKeys.iterator();
                while (iterator.hasNext()) {
                    SelectionKey next = iterator.next();
                    iterator.remove();
                    ServerSocketChannel channel = (ServerSocketChannel) next.channel();
                    SocketChannel serverChannel = null;
                    SelectionKey serverKey = null;
                    try {
                        serverChannel = channel.accept();
                        serverChannel.configureBlocking(false);
                        serverChannel.register(selectorRead, SelectionKey.OP_READ);
                    } catch (IOException e) {
                        e.printStackTrace();
                    }

                }
            }
        }
    }

    public void read() {
        while (true) {
            int action = 0;
            try {
                action = selectorRead.select(2000);
            } catch (IOException e) {
                e.printStackTrace();
            }
            if (action > 0) {
                System.out.println("可读");
                Set<SelectionKey> selectionKeys = selectorRead.selectedKeys();
                Iterator<SelectionKey> iterator = selectionKeys.iterator();
                while (iterator.hasNext()) {
                    SelectionKey next = iterator.next();
                    iterator.remove();
                    SocketChannel reqChannel = (SocketChannel) next.channel();
                    SocketChannel resChannel = (SocketChannel) next.attachment();
                    if (resChannel == null) {
                        try {
                            SocketChannel socketChannel = connectType(reqChannel);
                            socketChannel.configureBlocking(false);
                            socketChannel.register(selectorRead, SelectionKey.OP_READ, reqChannel);
                        } catch (IOException | ExecutionException | InterruptedException | TimeoutException e) {
                            e.printStackTrace();
                            try {
                                reqChannel.close();
                                next.cancel();
                            } catch (IOException ex) {
                                ex.printStackTrace();
                            }
                        }
                    } else {
                        try {
                            if (!reqChannel.isConnected() || !resChannel.isConnected())
                                throw new IOException();
                            leaf(reqChannel, resChannel);
                        } catch (IOException | InterruptedException | ExecutionException | TimeoutException | RuntimeException e) {
                            try {
                                reqChannel.close();
                                resChannel.close();
                                next.cancel();
                                resChannel.keyFor(selectorRead).cancel();
                            } catch (IOException ex) {
                                ex.printStackTrace();
                            }
                        }
                    }
                }
            }

        }
    }

    public SocketChannel connectType(SocketChannel channel) throws IOException, ExecutionException, InterruptedException, TimeoutException {
        ReadData readData = readData(channel);
        int read = readData.getRead();
        ByteBuffer buffer = readData.getBuffer();
        String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
        channel.write(ByteBuffer.wrap(connectResponse.getBytes(StandardCharsets.UTF_8)));
        Map<String, String> host = getHost(buffer.array(), read);
        SocketChannel clientChannel = SocketChannel.open();
        AtomicReference<Thread> thread = new AtomicReference<>();
        FutureTask<Integer> futureTask = new FutureTask<>(() -> {
            thread.set(Thread.currentThread());
            try {
                clientChannel.connect(new InetSocketAddress(host.get("url"), Integer.parseInt(host.get("port"))));
            } catch (IOException e) {
                e.printStackTrace();
//                System.out.println("连接失败" + e.getMessage()+"  }" + host.get("url"));
            }
            return 1;
        });
        threadPool.execute(futureTask);
        try {
            futureTask.get(200, TimeUnit.MILLISECONDS);
        } catch (InterruptedException | ExecutionException | TimeoutException e) {
            thread.get().interrupt();
//            System.out.println("超时连接"+host.get("url"));
        }
        if (buffer.get(0) != 67 && clientChannel != null && clientChannel.isConnected()) {
            clientChannel.write(buffer.flip());
        }
        return clientChannel;
    }

    public Map<String, String> getHost(byte[] bytes, int num) {
        HashMap<String, String> host = new HashMap<>();
        String url = new String(bytes, 81, num - 81);
        System.out.println("请求数据"+new String(bytes,0,num));
        host.put("url", url);
        host.put("port", "443");
        System.out.println("请求地址："+host.get("url"));
        return host;
    }


    public ReadData readData(SocketChannel channel) throws IOException, ExecutionException, InterruptedException, TimeoutException {
        ArrayList<byte[]> datas = new ArrayList<>(10);
        ReadData readData = new ReadData();
        AtomicReference<Thread> thread = new AtomicReference<>();
        FutureTask<Integer> futureTask = new FutureTask<>(() -> {
            thread.set(Thread.currentThread());
            ByteBuffer buffer = null;
            int sum = 0;
            do {
                ByteBuffer allocate = ByteBuffer.allocate(1024);
                int readNum = 0;
                try {
                    readNum = channel.read(allocate);
                } catch (IOException e) {
                    if (e instanceof ClosedChannelException) {
                    }
                    e.printStackTrace();
                    return 1;
                }
                if (readNum == -1) {
                    return 1;
                }
                if (readNum < 1024) {
                    sum += readNum;
                    buffer = ByteBuffer.allocate(sum);
                    for (byte[] bytes : datas) {
                        buffer.put(bytes);
                    }
                    buffer.put(allocate.array(), 0, readNum);
                    readData.setRead(sum);
                    break;
                }
                sum += readNum;
                datas.add(allocate.array());
            } while (true);

            readData.setBuffer(buffer);
            return null;
        });
        threadPool.execute(futureTask);
        Integer i;
        try {
            i = futureTask.get(50, TimeUnit.MILLISECONDS);
        } catch (InterruptedException | ExecutionException | TimeoutException e) {
            e.printStackTrace();
            thread.get().interrupt();
            throw e;
        }
        if (i != null) {
            throw new IOException();
        }
        return readData;
    }


    public void leaf(SocketChannel reqChannel, SocketChannel resChannel) throws IOException, InterruptedException, ExecutionException, TimeoutException {
        ReadData readData = readData(reqChannel);
        int read = readData.getRead();
        ByteBuffer buffer = readData.getBuffer();
        if (buffer == null) {
            return;
        }
        buffer.flip();
        resChannel.write(buffer);
    }

    public static void main(String[] args) {
        NioServerA nioServer = new NioServerA();
        CompletableFuture.runAsync(() -> {
            nioServer.accept();
        });
        CompletableFuture.runAsync(() -> {
            nioServer.read();
        });
        addHook();
        try {
            LOCK.lock();
            STOP.await();
        } catch (InterruptedException e) {
            e.printStackTrace();
        } finally {
            LOCK.unlock();
        }
    }

    private static void addHook() {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println(1);
        }));
    }
}
