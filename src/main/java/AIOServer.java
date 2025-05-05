import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.AsynchronousChannelGroup;
import java.nio.channels.AsynchronousServerSocketChannel;
import java.nio.channels.AsynchronousSocketChannel;
import java.nio.channels.CompletionHandler;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.*;

public class AIOServer {
    public static void main(String[] args) throws IOException, InterruptedException {
        final int port = 1080;
        ThreadPoolExecutor threadPool = new ThreadPoolExecutor(
                50,//池中保留的线程数
                50,//池中允许最大线程数
                3,   //多余线程最大空闲时间
                TimeUnit.SECONDS,  //时间单位
                new LinkedBlockingQueue<>(3),//超过核心线程数后，保存多余线程的队列
                Executors.defaultThreadFactory(),    //创建新线程时使用的工厂
                new ThreadPoolExecutor.DiscardOldestPolicy()//线程被阻塞时使用的处理方法
        );
        AsynchronousChannelGroup group = AsynchronousChannelGroup.withThreadPool(threadPool);
        //首先打开一个ServerSocket通道并获取AsynchronousServerSocketChannel实例：
        AsynchronousServerSocketChannel serverSocketChannel = AsynchronousServerSocketChannel.open(group);
        //绑定需要监听的端口到serverSocketChannel:
        serverSocketChannel.bind(new InetSocketAddress(port));
        CompletionHandler<AsynchronousSocketChannel, Object> handler = new CompletionHandler<AsynchronousSocketChannel,
                Object>() {
            @Override
            public void completed(final AsynchronousSocketChannel serverChannel, final Object attachment) {
                serverSocketChannel.accept("", this);
                // 继续监听下一个连接请求
                try {
                    AsynchronousSocketChannel clientChannel = connect(serverChannel);

                    https(serverChannel,clientChannel);
                } catch (IOException | InterruptedException | ExecutionException e) {
                    e.printStackTrace();
                }

            }

            @Override
            public void failed(final Throwable exc, final Object attachment) {
                System.out.println("出错了：" + exc.getMessage());
            }
        };
        serverSocketChannel.accept("", handler);
        TimeUnit.SECONDS.sleep(10000);

    }
    public static void https(AsynchronousSocketChannel serverChannel,AsynchronousSocketChannel clientChannel) throws ExecutionException, InterruptedException {
        System.out.println(Thread.currentThread().getName());
        TimeUnit.MILLISECONDS.sleep(500);
        ByteBuffer allocate = ByteBuffer.allocate(102400);
        serverChannel.read(allocate, 5, TimeUnit.SECONDS, null, new CompletionHandler<Integer, Object>() {
            @Override
            public void completed(Integer result, Object attachment) {
                clientChannel.write(ByteBuffer.wrap(allocate.array(),0,result), 5, TimeUnit.SECONDS, null, new CompletionHandler<Integer, Object>() {
                    @Override
                    public void completed(Integer result, Object attachment) {
                        try {
                            TimeUnit.MILLISECONDS.sleep(500);
                            https(clientChannel,serverChannel);

                        } catch (ExecutionException e) {
                            e.printStackTrace();
                        } catch (InterruptedException e) {
                            e.printStackTrace();
                        }
                    }

                    @Override
                    public void failed(Throwable exc, Object attachment) {
                        System.out.println("错误"+exc.getMessage());
                    }
                });
            }

            @Override
            public void failed(Throwable exc, Object attachment) {

            }
        });

    }


    public static AsynchronousSocketChannel connect(AsynchronousSocketChannel serverChannel) throws IOException, ExecutionException, InterruptedException {
        ByteBuffer allocate = ByteBuffer.allocate(10240);
        Integer num = serverChannel.read(allocate).get();
        Map<String, String> host = getHost(allocate.array());
        if (allocate.get(0) == 67) {
            String connectResponse = "HTTP/1.1 200 Connection Established" + "\r\n" + "\r\n";
            serverChannel.write(ByteBuffer.wrap(connectResponse.getBytes(StandardCharsets.UTF_8)));
            AsynchronousSocketChannel client = AsynchronousSocketChannel.open();
            System.out.println(host.get("url"));
            try {
                client.connect(new InetSocketAddress(host.get("url"), Integer.valueOf(host.get("port")))).get();
            } catch (ExecutionException e) {
                System.out.println(e.getMessage()+"===="+host.get("url"));
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
            return client;
        }

        AsynchronousSocketChannel client = AsynchronousSocketChannel.open();
        client.connect(new InetSocketAddress(host.get("url"), Integer.valueOf(host.get("port"))));
        Integer integer = client.write(allocate).get();
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
