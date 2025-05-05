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

public class NioServerNO {
    private static final ReentrantLock LOCK = new ReentrantLock();
    private static final Condition STOP = LOCK.newCondition();
    private Selector selector;
    private Selector selectorRead;
    private ServerSocketChannel serverSocketChannel;
    private int port = 1080;
    ThreadPoolExecutor threadPool;


    public NioServerNO() {
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
                action = selector.select(1000);
            } catch (IOException e) {
                e.printStackTrace();
            }
            if (action > 0) {
                Set<SelectionKey> selectionKeys = selector.selectedKeys();
                Iterator<SelectionKey> iterator = selectionKeys.iterator();
                while (iterator.hasNext()) {
                    SelectionKey next = iterator.next();
                    iterator.remove();
                    ServerSocketChannel channel = (ServerSocketChannel) next.channel();
                    SocketChannel clientChannel = null;
                    SocketChannel serverChannel = null;
                    SelectionKey serverKey=null;
                    SelectionKey clientKey=null;
                    try {
                        serverChannel = channel.accept();
                        clientChannel = connectType(serverChannel);
                        if (!clientChannel.isConnected()) {
                            serverChannel.close();
                            continue;
                        }
                        clientChannel.configureBlocking(false);
                        serverChannel.configureBlocking(false);
                        serverKey = serverChannel.register(selectorRead, SelectionKey.OP_READ, clientChannel);
                        clientKey = clientChannel.register(selectorRead, SelectionKey.OP_READ, serverChannel);

                    } catch (IOException | ExecutionException | InterruptedException | TimeoutException e) {
                        if (clientChannel != null) {
//                            e.printStackTrace();
                            throw new NullPointerException();
                        }
                        try {
                            if (serverKey != null || clientKey != null) {
                                serverKey.cancel();
                                clientKey.cancel();
                            }
                            if (serverChannel!=null)
                            serverChannel.close();
                            if (clientChannel!=null)
                            clientChannel.close();
                        } catch (IOException ex) {
//                            ex.printStackTrace();
                        }
//                        e.printStackTrace();
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
//                e.printStackTrace();
            }
            if (action > 0) {
                Set<SelectionKey> selectionKeys = selectorRead.selectedKeys();
                Iterator<SelectionKey> iterator = selectionKeys.iterator();
                while (iterator.hasNext()) {
                    SelectionKey next = iterator.next();
                    iterator.remove();
                    SocketChannel reqChannel = (SocketChannel) next.channel();
                    SocketChannel resChannel = (SocketChannel) next.attachment();
                    try {
                        if (!reqChannel.isConnected()||!resChannel.isConnected())
                            throw new IOException();
                        leaf(reqChannel, resChannel);
                    } catch (IOException | InterruptedException | ExecutionException | TimeoutException e) {
                        try {
                            reqChannel.close();
                            resChannel.close();
                            next.cancel();
                            resChannel.keyFor(selectorRead).cancel();
                        } catch (IOException ex) {
//                            ex.printStackTrace();
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
        Map<String, String> host = getHost(buffer.array());

        if (buffer.get(0) == 67) {
            String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
            channel.write(ByteBuffer.wrap(connectResponse.getBytes(StandardCharsets.UTF_8)));
        }
        SocketChannel clientChannel = SocketChannel.open();
        AtomicReference<Thread> thread=new AtomicReference<>();
        FutureTask<Integer> futureTask = new FutureTask<>(() -> {
            thread.set(Thread.currentThread());
            try {
                clientChannel.connect(new InetSocketAddress(host.get("url"), Integer.parseInt(host.get("port"))));
            } catch (IOException e) {
                //System.out.println("连接失败" + e.getMessage() + host.get("url"));
            }
            return 1;
        });
        threadPool.execute(futureTask);
        try {
            futureTask.get(2, TimeUnit.SECONDS);
        } catch (InterruptedException | ExecutionException | TimeoutException e) {
            thread.get().interrupt();
            //System.out.println("超时连接"+host.get("url"));
        }
        if (buffer.get(0)!=67&&clientChannel != null && clientChannel.isConnected()) {
            clientChannel.write(buffer.flip());
        }
        return clientChannel;
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
            host.put("port", "80");
        } else {
            host.put("port", new String(bytes, ps, pe - ps));
        }
        host.put("url", new String(bytes, s, e - s));
//        System.out.println("请求地址："+host.get("url"));
        return host;
    }

    public ReadData readData(SocketChannel channel) throws IOException, ExecutionException, InterruptedException, TimeoutException {
        ArrayList<byte[]> datas = new ArrayList<>(10);
        ReadData readData = new ReadData();
        AtomicReference<Thread> thread=new AtomicReference<>();
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
//                    e.printStackTrace();
                    return 1;
                }
                if (readNum == -1) {
                    return 1;
                }
                if (readNum < 1024) {
                    buffer = ByteBuffer.allocate(sum + readNum);
                    for (byte[] bytes : datas) {
                        buffer.put(bytes);
                    }
                    buffer.put(allocate.array(), 0, readNum);
                    readData.setRead(readNum);
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
            i = futureTask.get(5, TimeUnit.SECONDS);
        } catch (InterruptedException | ExecutionException | TimeoutException e) {
//            e.printStackTrace();
            thread.get().interrupt();
            throw e;
        }
        if (i!=null) {
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

    public static void main(String[] args){
        NioServerNO nioServer = new NioServerNO();
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
//            e.printStackTrace();
        }finally {
            LOCK.unlock();
        }
    }

    private static void addHook() {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println(1);
        }));
    }
}
