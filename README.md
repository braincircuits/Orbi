# HTTP/3 多路复用代理

Java 25 + Netty 4.2.18.Final。客户端提供本地 HTTP 代理入口，与服务端复用一条经过 TLS 认证的 QUIC/HTTP/3 连接；每个需要远程代理的连接使用独立的 HTTP/3 CONNECT 流。服务端为每个流建立目标 TCP 连接。

```text
浏览器/应用 -- 本地 TCP --> ClientG
                              ║ 一条 QUIC/HTTP/3 连接（UDP + TLS）
                              ║ 多个独立 CONNECT 流
                            Server -- 多个 TCP 连接 --> 目标网站
```

## 构建与测试

需要 JDK 25、Maven 3.9。HTTP/3 依赖包含 QUIC 原生库，打包时保留其平台资源。

```sh
mvn test
mvn -DskipTests package
```

打包后可运行 `python3 scripts/smoke-test.py`，自动启动两个 JAR，验证普通 HTTP 与 CONNECT 转发。

产物是可独立启动的完整 JAR：

- `Server/target/Server-1.0-SNAPSHOT.jar`
- `ClientG/target/clientG-1.0-SNAPSHOT.jar`

集成测试启动真实的本地 TCP/UDP 服务，覆盖并发流复用、拆包、请求体、半关闭、认证、证书校验、目标失败、直连规则和连接重建。测试不需要访问公网。`ClientG/src/test/resources/tls` 中的公开证书和私钥仅为测试夹具，不能用于部署。

## 本机体验

以下脚本生成独立的 `.local-h3/` 配置、随机密码和 localhost 自签名证书，不覆盖已有配置。需要支持 `-addext` 的 OpenSSL。

```sh
sh scripts/create-local-config.sh
java --enable-native-access=ALL-UNNAMED -jar Server/target/Server-1.0-SNAPSHOT.jar .local-h3/server.properties
```

另开终端：

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar .local-h3/client.properties
```

浏览器设置 HTTP/HTTPS 代理为 `127.0.0.1:8080`，或使用：

```sh
curl --proxy http://127.0.0.1:8080 https://example.com/
curl --proxy http://127.0.0.1:8080 http://example.com/
```

## IDEA 手动 hello world 测试

两个测试类均有 `main` 方法，直接点击 IDEA 的运行按钮即可。数据路径为：

```text
ProxyHelloSender → ClientApplication → HTTP/3 → NettyServer → ProxyHelloReceiver
```

1. 运行 `Server/src/test/java/com/blacicada/manual/ProxyHelloReceiver.java`，默认监听 `127.0.0.1:18080`。
2. 运行代理服务端 `NettyServer` 和代理客户端 `ClientApplication`。使用上面的本机配置时，工作目录设置为项目根目录，Program arguments 分别填写 `.local-h3/server.properties` 和 `.local-h3/client.properties`；VM options 填写 `--enable-native-access=ALL-UNNAMED`。
3. 运行 `ClientG/src/test/java/com/blacicada/manual/ProxyHelloSender.java`。默认连接 `127.0.0.1:8080`，发送 `CONNECT 127.0.0.1:18080`，收到成功响应后发送 `hello world`。
4. 接收端控制台打印收到的数据并原样回显，发送端打印 `代理通信测试成功`。接收端保持监听，可重复运行发送端；测试结束后点击 Stop 停止接收端及代理进程。

发送端参数可覆盖为 `proxyHost proxyPort targetHost targetPort`；接收端参数为 `bindHost port`，也可直接修改类顶部的默认常量。目标地址由**代理服务端**访问：跨机器测试时填写服务端能访问的接收端 IP，并使接收端监听对应网卡地址。客户端直连列表应保持为空，确保此次测试经过 HTTP/3 服务端。

## 部署配置

参考 `examples/server.properties` 和 `examples/client.properties`。所有相对文件路径均相对于所传入的 properties 文件目录。默认读取当前目录的 `server.properties` / `client.properties`，原来的这两个文件未被覆盖。

服务端：

| 配置 | 含义 |
| --- | --- |
| `bind` / `port` | HTTP/3 的 UDP 监听地址与端口；默认 `0.0.0.0:4433` |
| `password` | 必填，与客户端一致的随机长密码 |
| `tls.cert` | PEM 证书链，默认 `certs/server.crt` |
| `tls.key` | PEM 私钥，默认 `certs/server.key` |

客户端：

| 配置 | 含义 |
| --- | --- |
| `bind` / `port` | 本地 HTTP 代理入口；默认 `127.0.0.1:8080` |
| `server.host` / `server.port` | 代理服务端地址与 UDP 端口 |
| `password` | 必填，每个 CONNECT 请求都进行认证 |
| `tls.serverName` | TLS 验证的服务端名称，默认等于 `server.host`，必须匹配证书 SAN |
| `tls.ca` | 可选的 PEM 信任证书；省略则使用系统/JDK 默认信任链 |
| `routesFile` | 直连域名列表，默认 `pac.txt`；不存在或为空则全部走远程代理 |
| `serversFile` | 未设置 `server.host` 时，兼容读取旧的编号服务器列表 `config.txt` |

两端均支持：

- `connectTimeoutMillis`：DNS/连接或 CONNECT 握手的等待限制，默认 10000 毫秒。本地初始请求整体等待限制为其两倍。
- `idleTimeoutSeconds`：共享 QUIC 连接空闲超时，默认 300 秒。
- `maxStreams`：流并发上限，默认 256。客户端计入正在等待建立的流，超限请求直接失败，不影响已有隧道。

远程部署需要开放服务端 UDP 端口。自签名部署将服务器证书配置为客户端 `tls.ca`；公开证书使用正常的信任链。程序不会跳过证书或主机名验证，也不启用 TLS 0-RTT。

## 转发行为与边界

- HTTPS：浏览器发出的 HTTP/1.1 CONNECT 在客户端解析，再通过远程 HTTP/3 CONNECT 建立隧道。目标 HTTPS 内容保持端到端加密，代理不解密目标 TLS。
- 普通 HTTP：支持各请求方法、Content-Length、chunked 和 `Expect: 100-continue`；请求体分块转发。当前每条本地普通 HTTP 连接只处理一个请求，并向目标发送 `Connection: close`。不支持普通 HTTP 的流水线请求或 WebSocket Upgrade；HTTPS 隧道内的连接复用和 WSS 不受此限制。
- `pac.txt` 中的域名及其子域名直接连接目标；空行与 `#` 注释忽略。使用域名集合匹配，不依赖哈希碰撞。
- HTTP/3 流关闭只清理对应目标连接；共享连接中断会使其已有隧道结束，下一次请求按需重新建立共享连接。不会重放请求或假装恢复已中断的 TCP 会话。
- 每个方向使用手动读取、写完成通知与可写状态传播背压；建立连接期间的应用缓冲有上限。目标 DNS 查询不阻塞网络事件线程。
- 没有 TCP/HTTP2 回退、SOCKS5、CONNECT-UDP 或 UDP 目标代理。
- 新旧客户端/服务端的线协议不兼容，必须成对升级。旧的 `key`、序号与字节映射实现已移除。

## 源码位置

- `ClientG/.../h3`：本地 HTTP 入口、共享会话、直连规则与请求转发。
- `Server/.../h3`：HTTP/3 监听、CONNECT 认证与目标连接。
- `ProxyCommon/.../h3`：配置、地址解析、HTTP/3 数据适配与双向转发。

旧协议 Handler、字节映射编解码、数据库实验资源和根目录 `src` 下的早期实验代码已清理。现有单元测试、HTTP/3 集成测试及两个可直接运行的 hello world 测试类均保留；IDEA 运行配置位于 `.run/`。
