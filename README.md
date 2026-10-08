# HTTP/2 与 HTTP/3 多路复用代理

Java 25 + Netty 4.2.18.Final。Flutter UI 称为「代理客户端」，Java ClientG 称为「代理内核」，Java Server 称为「代理服务端」。代理内核提供本地 HTTP 代理入口，支持保存多份连接配置并切换默认连接，每份配置选择 HTTP/2 或 HTTP/3；每个代理隧道使用独立的 CONNECT 流。

```text
浏览器/应用 -- 本地 TCP --> ClientG
                              ║ HTTP/3（QUIC/UDP）或 HTTP/2（TLS/TCP）
                              ║ 多个独立 CONNECT 流
                            Server -- 多个 TCP 连接 --> 目标网站
```

## 使用入口

- 已有发布目录：按下面的「发布目录启动与远程部署」启动，不需要 Maven。
- 从源码构建：安装 JDK 25、Maven 3.9，以及支持 `-addext` 的 OpenSSL（生成证书使用）。
- 配置直连网段：查看「PAC 直连规则」，修改客户端实际使用的规则文件。

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

## 发布目录启动与远程部署

在项目根目录执行以下命令。脚本会构建并运行测试，生成未压缩的发布目录：

```sh
sh scripts/package-release.sh
```

```text
release/
├── README.md
├── server/
│   ├── server.jar
│   ├── start.sh / start.cmd / background.sh
│   ├── config/server.properties、users.properties
│   └── certs/server.crt、server.key
└── client/
    ├── client.jar
    ├── start.sh / start.cmd / background.sh
    ├── config/kernel.json、pac.txt
    └── certs/server.crt
```

在两个终端分别启动服务端和客户端：

```sh
./release/server/start.sh
```

```sh
./release/client/start.sh
```

脚本支持从任意工作目录调用，优先使用 `JAVA_HOME` 中的 Java，否则使用 PATH 中的 `java`。运行机器需要 JDK 25，无需 Maven。Windows 在命令提示符中分别执行 `release\server\start.cmd` 和 `release\client\start.cmd`。进程在前台运行，日志输出到终端，按 Ctrl+C 停止。

默认生成的配置可以直接在本机使用：服务端监听 UDP `4433`，客户端连接本机服务端，并提供 TCP `127.0.0.1:8080` HTTP 代理入口。

远程部署步骤：

1. 将整个 `release/server/` 复制到服务端机器，将整个 `release/client/` 复制到客户端机器，保留各自内部目录结构。
2. 编辑客户端 `config/kernel.json`，在各连接的 `config` 中把 `server.host` 改为服务端可访问的 IP 或域名。`server.port` 必须与服务端 `port` 一致。
3. 在服务端防火墙、安全组及必要的路由器端口转发中放行对应 **UDP** 端口，默认 `4433`。
4. 保持客户端 `username`、`password` 与服务端账号文件对应。使用脚本生成的证书时，保留 `tls.serverName=localhost` 和 `tls.ca=../certs/server.crt`；连接地址与证书验证名称是两个独立配置。
5. 先启动服务端，再启动代理内核；通过管理接口调用 `/api/v1/proxy/start` 开启转发，然后将浏览器/应用的 HTTP 和 HTTPS 代理地址均设为 `127.0.0.1:8080`。本地代理入口使用 HTTP，HTTPS 网站通过 CONNECT 隧道访问。

每次打包生成默认账号 `client1` 的随机密码及有效期 365 天的自签名证书。客户端只需要公开证书，私钥保留在服务端。更换证书时需同步客户端信任证书及 `tls.serverName`，名称必须匹配新证书的 SAN；证书到期需要手动更新。客户端目录含访问凭证，只分发给获准使用代理的用户。

发布目录已被 Git 忽略。脚本拒绝覆盖已有目录；再次生成可使用 `sh scripts/package-release.sh /tmp/network-release-next`。升级现有部署时，停止两端进程，将新构建的两个 JAR 分别替换为 `server/server.jar` 和 `client/client.jar`，保留原有配置、PAC 和证书后重启。不要混用不同次打包生成的密码或证书。

发布目录自带的说明来源于 [发布使用说明模板](scripts/release/README.md)。

## Linux / macOS 后台运行

发布目录中的客户端和服务端均提供 `background.sh`。支持 Linux 和 macOS，需要 JDK 25。Linux 需要 `flock`（通常由 `util-linux` 提供），macOS 使用系统自带工具。以下命令从发布目录执行，客户端将 `server` 替换为 `client`：

```sh
./server/background.sh start
./server/background.sh status
./server/background.sh stop
./server/background.sh restart
```

不传参数时默认执行 `start`。脚本使用 `nohup`，关闭终端后进程继续运行；支持从任意工作目录调用，并沿用 `start.sh` 的 `JAVA_HOME` 和配置路径。请使用同一个系统用户管理进程，且不要同时通过前台脚本和后台脚本启动同一实例。

日志追加到各自目录的 `logs/app.log`，进程信息保存在 `run/app.pid`。例如查看服务端日志：

```sh
tail -f server/logs/app.log
```

重复启动不会创建第二个后台实例；停止时发送 SIGTERM，最多等待 30 秒，超时保留进程信息并报告错误，不强制杀进程。`status` 在运行时返回 0，未运行时返回 1。启动提示只确认进程仍存活，是否监听成功请查看日志。

macOS 使用目录锁防止管理命令并发执行；若命令被强制终止后留下 `run/control.lock.d`，确认没有管理命令运行后，可使用 `rmdir` 删除该空目录再重试。

脚本不会注册开机自启、崩溃重启或日志轮转；需要这些功能时可按系统另行配置 systemd、launchd 或日志轮转工具。重新打包会自动附带此脚本。

## 源码构建后的本机体验

以下脚本生成独立的 `.local-h3/` 配置、随机密码和 localhost 自签名证书，不覆盖已有配置。需要支持 `-addext` 的 OpenSSL。

```sh
sh scripts/create-local-config.sh
java --enable-native-access=ALL-UNNAMED -jar Server/target/Server-1.0-SNAPSHOT.jar .local-h3/server.properties
```

另开终端：

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web --config .local-h3/kernel.json
```

浏览器设置 HTTP/HTTPS 代理为 `127.0.0.1:8080`，或使用：

```sh
curl --proxy http://127.0.0.1:8080 https://example.com/
curl --proxy http://127.0.0.1:8080 http://example.com/
```

## IDEA 手动 hello world 测试

先使用 JDK 25 导入 Maven 项目，并执行 `sh scripts/create-local-config.sh` 生成本机配置。项目已提供 `.run/` 运行配置，依次启动 `HTTP3 Receiver`、`HTTP3 Server`、`HTTP3 Client`、`HTTP3 Sender` 即可。

两个测试类均有 `main` 方法，也可以直接点击 IDEA 的运行按钮。数据路径为：

```text
ProxyHelloSender → ClientApplication → HTTP/3 → NettyServer → ProxyHelloReceiver
```

1. 运行 `Server/src/test/java/com/blacicada/manual/ProxyHelloReceiver.java`，默认监听 `127.0.0.1:18080`。
2. 运行代理服务端 `NettyServer` 和代理内核 `ClientApplication`，通过管理接口调用 `/api/v1/proxy/start` 开始转发后，再运行发送端。使用上面的本机配置时，工作目录设置为项目根目录，Program arguments 分别填写 `.local-h3/server.properties` 和 `--web --config .local-h3/kernel.json`；VM options 填写 `--enable-native-access=ALL-UNNAMED`。
3. 运行 `ClientG/src/test/java/com/blacicada/manual/ProxyHelloSender.java`。默认连接 `127.0.0.1:8080`，发送 `CONNECT 127.0.0.1:18080`，收到成功响应后发送 `hello world`。
4. 接收端控制台打印收到的数据并原样回显，发送端打印 `代理通信测试成功`。接收端保持监听，可重复运行发送端；测试结束后点击 Stop 停止接收端及代理进程。

发送端参数可覆盖为 `proxyHost proxyPort targetHost targetPort`；接收端参数为 `bindHost port`，也可直接修改类顶部的默认常量。目标地址由**代理服务端**访问：跨机器测试时填写服务端能访问的接收端 IP，并使接收端监听对应网卡地址。客户端直连列表应保持为空，确保此次测试经过 HTTP/3 服务端。

## 部署配置

参考 `examples/server.properties` 和 `examples/kernel.json`。相对路径以各自配置文件所在目录为基准。代理服务端默认读取 `server.properties`，代理内核默认读取 `kernel.json`；内核不再接受 properties 或编号服务器列表。

服务端：

| 配置 | 含义 |
| --- | --- |
| `bind` / `port` | HTTP/3 的 UDP 监听地址与端口；默认 `0.0.0.0:4433` |
| `password` | 共享密码模式下必填；启用 `usersFile` 后不再使用 |
| `usersFile` | 可选的独立账号文件路径；配置后仅接受账号认证 |
| `tls.cert` | PEM 证书链，默认 `certs/server.crt` |
| `tls.key` | PEM 私钥，默认 `certs/server.key` |

代理内核：本地字段放在 `local` 中，其余连接字段放在 `connections[].config` 中。

| 配置 | 含义 |
| --- | --- |
| `local.bind` / `local.port` | 本地 HTTP 代理入口；默认 `127.0.0.1:8080` |
| `server.host` / `server.port` | 代理服务端地址与所选协议的端口 |
| `username` | 独立账号模式下必填；省略时使用旧的共享密码模式 |
| `password` | 必填，账号密码或旧模式的共享密码；每个 CONNECT 请求均认证 |
| `tls.serverName` | TLS 验证的服务端名称，默认等于 `server.host`，必须匹配证书 SAN |
| `tls.ca` | 可选的 PEM 信任证书；省略则使用系统/JDK 默认信任链 |
| `local.routesFile` | 直连域名/IP/CIDR 规则列表，默认 `pac.txt`；不存在或为空则全部走远程代理 |

两端均支持：

- `connectTimeoutMillis`：DNS/连接或 CONNECT 握手的等待限制，默认 10000 毫秒。本地初始请求整体等待限制为其两倍。
- `idleTimeoutSeconds`：共享 QUIC 连接空闲超时，默认 300 秒。
- `maxStreams`：流并发上限，默认 256。客户端计入正在等待建立的流，超过本地上限的请求直接失败，不影响已有隧道。服务端 QUIC 流额度暂时耗尽时，客户端等待 MAX_STREAMS 更新后继续创建流，等待最长为 `connectTimeoutMillis`，不会为此断开共享连接。

远程部署需要开放服务端 UDP 端口。自签名部署将服务器证书配置为客户端 `tls.ca`；公开证书使用正常的信任链。程序不会跳过证书或主机名验证，也不启用 TLS 0-RTT。

## 多客户端与独立账号

一个服务端可以同时接受多个客户端；每个客户端进程各自建立一条 QUIC 连接并复用自己的代理流。`maxStreams` 按连接计算，不是全服务端的总额度。同一账号可在多台机器上使用，当前不限制每账号设备数量。

服务端 `config/server.properties` 启用账号文件：

```properties
usersFile=users.properties
```

在同目录创建 UTF-8 编码的 `users.properties`，每个账号一个独立密码：

```properties
client1=替换为客户端1的随机长密码
client2=替换为客户端2的随机长密码
```

账号名为 1 至 64 位字母、数字、下划线、点或连字符，且以字母或数字开头。文件采用 Java properties 格式，反斜杠需按该格式转义；推荐用 `openssl rand -hex 32` 生成密码。空文件、空密码、重复或非法账号会阻止服务端启动。

代理内核 1 的 `config/kernel.json` 中，在所选连接的 `config` 对象内填写：

```json
{"username":"client1","password":"替换为客户端1的随机长密码"}
```

客户端 2 填写 `username=client2` 及对应密码。两者连接相同的 `server.host` 和 `server.port`，使用同一份服务端公开证书。不要分发服务端私钥或完整账号文件。不同机器都可使用本地端口 `8080`；同机运行多个客户端时，每个实例使用独立目录及不同本地 `port`。

每个 CONNECT 流都会验证账号和密码，认证信息由 TLS 加密传输，不记录到日志。启用 `usersFile` 后，即使仍配置服务端 `password`，也不再接受旧的共享密码认证；未配置 `usersFile` 时保持旧模式，客户端省略 `username`，两端 `password` 相同即可。

新增、删除账号或修改密码后重启服务端；代理内核在 Web 模式下修改连接账号配置后立即重建当前会话，通过接口修改后立即生效。重启服务端会断开所有现有客户端连接，后续请求按需重连。当前不提供账号热更新、每账号带宽限制或每账号连接总数限制。

新生成的发布目录默认启用账号模式，创建随机密码的 `client1` 并写入配套客户端配置。既有发布目录的凭证不会因更新 JAR 自动切换认证模式。

## PAC 直连规则（域名、IP 与网段）

这里的 `pac.txt` 是**客户端读取的直连列表**，不是浏览器执行的 JavaScript PAC 脚本。浏览器仍配置普通 HTTP 代理，不要把此文件填到浏览器的自动代理配置 URL 中。规则命中时由客户端直接连接目标，不经过 HTTP/3 服务端；未命中时走远程代理。普通 HTTP 和 HTTPS CONNECT 都适用。

### 修改哪个文件

| 启动方式 | 默认规则文件 |
| --- | --- |
| 发布目录启动脚本 | `release/client/config/pac.txt`（部署后为客户端目录下的 `config/pac.txt`） |
| `.local-h3` 本机配置 / IDEA 保存的运行配置 | `.local-h3/pac.txt` |
| 自定义配置文件 | `routesFile` 指向的文件；相对路径以该 JSON 文件所在目录为基准 |

例如发布配置 `release/client/config/kernel.json` 的 `local` 对象中设置：

```json
{"routesFile":"pac.txt"}
```

此时读取同目录的 `pac.txt`，不会读取项目根目录同名文件。文件不存在、为空或只有注释时，全部目标走远程代理。程序不会自动添加内网直连规则。

### 网段配置示例

按需将以下内容写入实际使用的 `pac.txt`，UTF-8 编码，每行一条：

```text
# 域名自身及其所有子域名直连；不填写协议、路径或端口
example.com

# 单个 IP 直连
192.168.1.10

# IPv4 内网和回环网段
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
127.0.0.0/8

# IPv6 回环和唯一本地地址网段
::1/128
fc00::/7
```

这些是可选示例，不是默认配置。仅需要 `192.168.1.*` 直连时，填写 `192.168.1.0/24` 即可，不必加入更大的 `192.168.0.0/16`。

| 写法 | 匹配范围 |
| --- | --- |
| `192.168.1.0/24` | `192.168.1.0` 至 `192.168.1.255` |
| `192.168.0.0/16` | `192.168.0.0` 至 `192.168.255.255` |
| `10.0.0.0/8` | `10.0.0.0` 至 `10.255.255.255` |
| `172.16.0.0/12` | `172.16.0.0` 至 `172.31.255.255` |
| `192.168.1.10/32` | 仅一个 IPv4 地址，等同于 `192.168.1.10` |
| `::1/128` | 仅 IPv6 回环地址 |
| `fc00::/7` | IPv6 唯一本地地址范围，包含 `fc` 和 `fd` 开头的地址 |

斜杠后的数字是网络前缀长度，数值越大范围越小；IPv4 为 0–32，IPv6 为 0–128。`0.0.0.0/0` 会使所有 IPv4 地址命中，`::/0` 会使所有 IPv6 地址命中，只有确实需要全量直连时才使用。

规则格式与加载行为：

- 域名忽略大小写，`example.com` 同时匹配自身和 `www.example.com` 等子域名。
- 忽略空行和 `#` 注释，也支持行尾注释，例如 `192.168.1.0/24 # 办公网`。
- 不支持 `*.example.com`、URL、端口、`192.168.*.*`、起止 IP 范围或 `255.255.255.0` 子网掩码写法。
- 所有规则都是直连规则，没有反向规则或按顺序覆盖机制。CIDR 中的主机位不影响匹配，建议填写规范网络地址。
- 非法 CIDR 会报告文件、行号和规则并阻止启动。调用直连规则更新/重载接口立即应用，新规则只影响新请求。无需重启服务端。

更多注释示例见 [examples/pac.txt](examples/pac.txt)。

### 域名如何匹配网段

1. 先检查域名规则，命中则客户端直接连接。
2. 域名未命中且列表中有 IP/CIDR 规则时，客户端异步解析域名，检查返回的 IP 地址。
3. 选择解析结果中第一个命中规则的 IP 并直接连接该 IP，避免再次解析改变目标。
4. 没有命中 IP 或本地 DNS 解析失败时，通过 HTTP/3 转发原域名，由服务端解析并连接。

因此添加网段规则后，未命中域名规则的域名也可能在客户端产生 DNS 查询。直连连接失败会返回错误，不会自动改走远程代理。直连时 `127.0.0.1` 指客户端自身；走代理时该地址指服务端自身。

## 常见问题

| 现象 | 检查方式 |
| --- | --- |
| 启动提示找不到配置、证书或私钥 | 使用启动脚本；服务端指定 properties 路径，代理内核使用 `--web --config kernel.json`；检查路径是否相对于配置文件目录，复制部署时是否保留 `certs/` |
| 启动提示端口占用 | 停止旧进程或修改 `port`；服务端修改端口后同步客户端 `server.port`，客户端修改端口后同步浏览器代理设置 |
| 客户端启动成功，但无法访问网站 | 共享 QUIC 连接按需建立，启动成功不代表已连接服务端；检查 `server.host`、端口以及 UDP 防火墙规则 |
| TLS 握手或证书校验失败 | 检查证书有效期、`tls.ca` 是否信任当前服务端证书，以及 `tls.serverName` 是否匹配证书 SAN |
| 返回 502 | 查看客户端和服务端终端日志；检查账号和密码、目标 DNS 和目标 TCP 可达性。直连目标由客户端访问，代理目标由服务端访问 |
| 返回 504 | 初始请求建立超时；检查网络和服务端可达性，再按需调整 `connectTimeoutMillis` |
| PAC 修改没有生效 | 确认 `routesFile` 实际指向的文件；Web 模式调用规则重载接口，其余模式重启代理内核，再建立新连接测试 |
| hello world 测试未经过服务端 | 清空测试配置的直连规则；回环地址或网段命中时会直接连接本机接收端 |

验证 HTTP 和 HTTPS 代理时可显式排除环境中 `NO_PROXY` 的影响：

```sh
curl --noproxy "" --proxy http://127.0.0.1:8080 http://example.com/
curl --noproxy "" --proxy http://127.0.0.1:8080 https://example.com/
```

这些命令访问公网，需目标网站可达；无公网环境可以使用前面的 IDEA hello world 测试或 `scripts/smoke-test.py`。

## 转发行为与边界

- HTTPS：浏览器发出的 HTTP/1.1 CONNECT 在客户端解析，再通过远程 HTTP/3 CONNECT 建立隧道。目标 HTTPS 内容保持端到端加密，代理不解密目标 TLS。
- 普通 HTTP：支持各请求方法、Content-Length、chunked 和 `Expect: 100-continue`；请求体分块转发。当前每条本地普通 HTTP 连接只处理一个请求，并向目标发送 `Connection: close`。不支持普通 HTTP 的流水线请求或 WebSocket Upgrade；HTTPS 隧道内的连接复用和 WSS 不受此限制。
- HTTP/3 流关闭只清理对应目标连接；共享连接中断会使其已有隧道结束，下一次请求按需重新建立共享连接。不会重放请求或假装恢复已中断的 TCP 会话。
- 每个方向使用手动读取、写完成通知与可写状态传播背压；建立连接期间的应用缓冲有上限。目标 DNS 查询不阻塞网络事件线程。
- HTTP/2 与 HTTP/3 由连接配置明确选择，不自动降级；没有 SOCKS5、CONNECT-UDP 或 UDP 目标代理。
- 新旧客户端/服务端的线协议不兼容，必须成对升级。旧的 `key`、序号与字节映射实现已移除。

## 源码位置

- `ClientG/.../h3`：本地 HTTP 入口、共享会话、直连规则与请求转发。
- `Server/.../h3`：HTTP/3 监听、CONNECT 认证与目标连接。
- `ProxyCommon/.../h3`：配置、地址解析、HTTP/3 数据适配与双向转发。

旧协议 Handler、字节映射编解码、数据库实验资源和根目录 `src` 下的早期实验代码已清理。现有单元测试、HTTP/3 集成测试及两个可直接运行的 hello world 测试类均保留；IDEA 运行配置位于 `.run/`。

### CONNECT 超时与连接恢复

CONNECT 超时后会取消对应请求流的双向传输。若整个等待期间 QUIC 有发包却完全没有回包，客户端会记录诊断日志并关闭疑似失效的共享连接，让后续请求重新连接。此时该连接上的已有隧道也会结束，应用需要重新发起请求；代理不会重放已发送的数据。

若 QUIC 仍正常回包，仅目标连接慢或流额度耗尽，不会因此关闭共享连接。超时日志包含目标地址或流额度，以及连接 ID；可结合服务端的 CONNECT 失败日志定位。

## Web 管理接口（唯一内核入口）

代理客户端通过本机 HTTP + JSON 操作代理内核，通过 SSE 订阅状态、日志与诊断结果。支持连接配置增删改、切换连接、启动/停止转发和热更新；UI 关闭后内核继续运行。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web --config kernel.json --port 9090
```

代理内核只接受 `--web` 入口，不再接受无参数启动或直接传入配置文件。启动脚本和 IDEA 配置也使用 Web 模式。启动后代理转发处于停止状态，UI 调用 `/api/v1/proxy/start` 开始转发。管理接口固定监听 `127.0.0.1`，默认发现文件为配置目录下的 `run/control.json`，包含管理地址和随机令牌；仅当前用户可读写。用 `--port 0` 自动分配管理端口。所有接口要求 `Authorization: Bearer <token>`，令牌不要放入 URL。

详细接口、请求示例、错误码、热更新规则和 Flutter 接入流程见 [Web 管理接口文档](docs/web-api.md)。修改本地代理监听地址/端口会立即重启转发并断开全部旧连接；管理接口保持运行。修改配置只应用到内存，调用保存接口后才会在进程重启后保留。


## 多连接配置与 HTTP/2

完整示例见 [examples/kernel.json](examples/kernel.json)。JSON 配置的相对路径以文件所在目录为基准，Web 接口直接提交的配置以 `--config` 文件所在目录为基准。代理内核只读取 JSON 格式；在每份连接的 `config` 中设置 `"protocol":"http2"` 或 `"protocol":"http3"`。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web --config examples/kernel.json
```

运行前替换示例中的服务器地址、账号和密码。示例默认使用系统信任证书；私有 CA 或自签名证书需要在每份连接的 `config` 中设置 `tls.ca`，且 `tls.serverName` 必须匹配证书。

- `version`：目前固定为 `1`。
- `local`：本地监听、直连规则与本地请求建立超时；`routesInline` 优先于 `routesFile`。
- `connections`：1 至 128 份配置，每份包含稳定的 `id`、显示名称 `name`、连接参数 `config`。
- `defaultConnectionId`：未命中直连规则时使用的连接 ID。
- 唯一性按协议、规范化地址和端口判断；相同端点不能重复保存不同账号。域名不通过 DNS 解析后的 IP 去重。带作用域标识的 IPv6 地址暂不支持。
- `protocol` 只接受 `http2`、`http3`，端口默认 `4433`。两种协议都复用单条连接承载多个 CONNECT 流，使用相同的认证机制。
- 本期只支持直连与默认代理选择；`SessionRouter` 是后续按域名选择不同配置的扩展入口，尚未实现域名到指定配置的规则。

切换默认配置会立即关闭旧协议会话、旧代理隧道及其浏览器连接，并取消排队请求。直连与本地监听不受影响，新请求按新配置连接。修改当前配置中的连接参数也会重建会话；仅修改名称不会中断。重复选择同一配置不会断开，若需强制重连使用 `connection.disconnect`。新配置连接失败不会回退或自动直连，也不会重放业务数据。无业务心跳。

代理服务端需升级 JAR 并在 `server.properties` 中启用对应协议：

```properties
protocols=http3,http2
port=4433
# 可选：HTTP/2 使用不同 TCP 端口；省略时沿用 port。
# http2.port=4434
```

HTTP/3 使用 UDP，HTTP/2 使用 TCP + TLS + ALPN `h2`，不支持明文 h2c。两者可以同时监听同一个数字端口，需分别放行防火墙中的 TCP/UDP。省略 `protocols` 时仍只启动 HTTP/3。两种协议共用服务端认证、证书及每会话流上限配置。

### 多配置控制接口

UI 统一使用 [Web 管理接口](docs/web-api.md)。连接配置管理使用 `/api/v1/profiles`，切换默认连接使用 `/api/v1/routing/default`，日志查询使用 `/api/v1/logs`，可通过 `levels=WARN,ERROR` 按级别筛选。

### 新增验证

`Http2IntegrationTest` 覆盖并发复用、认证、证书、半关闭、反复取消上传/下载、额度排队、重连和 GOAWAY；`MultiConnectionIntegrationTest` 验证 HTTP/3 与 HTTP/2 双向切换时旧隧道和排队请求终止、直连与监听保持。`KernelConfigTest` 和 `ControlHttpServerTest` 验证唯一性、脱敏、保存及控制命令。

```sh
mvn test
python3 scripts/smoke-test.py --protocol http2
python3 scripts/smoke-test.py --protocol http3
```

两个冒烟命令需先构建 JAR，均只访问本机测试服务。

### HTTP/2 隧道建立超时诊断

HTTP/2 超时日志按实际阶段分别显示“等待 HTTP/2 流额度”“创建 HTTP/2 流”“发送 HTTP/2 CONNECT”或“等待 HTTP/2 CONNECT 响应”。日志包含目标、连接 ID、流 ID、本地与服务端地址、对端并发上限、本连接占用、排队数量、当前阶段耗时和总等待时间。未创建流时，流 ID 显示“未分配”。

额度占用包含已预留但尚未完成创建的流；排队数量包含当前仍等待额度的请求。额度等待、流创建、请求发送和响应等待共用原有的 `connectTimeoutMillis` 预算，切换阶段不会重新计时。进入响应等待只表示本地写入完成，不证明服务端已收到或处理 CONNECT。

两端日志里的连接 ID 是各自本地的 Channel ID，不能直接按相同值匹配。应结合连接地址、端口、时间及 HTTP/2 流 ID 对照。该诊断改进不会仅因某个请求超时就重建共享连接，也不代表已经确定超时根因。

## 代理内核代码分层

| 组件 | 职责 |
| --- | --- |
| `ClientApplication` / `WebApplication` | 唯一 Web 启动入口、启动参数与进程退出管理 |
| `ControlHttpServer` | HTTP 监听、鉴权、CORS、请求大小和并发限制、响应写入、SSE 传输 |
| `ControlApi` | API 路由、请求字段及版本头解析、统一响应快照；不直接操作套接字 |
| `KernelControl` | 协调配置应用、版本提交、持久化、状态和事件；作为业务操作入口 |
| `ConfigurationEditor` | 配置合并、密码保留和校验，只产生候选配置，不修改运行状态 |
| `ProxyRuntime` | 代理启停、监听重启与失败恢复；不接触 HTTP 请求或配置文件 |
| `ControlTasks` | 有界异步诊断及取消，与实际代理会话独立 |
| `ProxySessionFactory` | 为正式转发和诊断统一创建 HTTP/2 或 HTTP/3 会话 |
| `SessionRouter` | 选择当前代理会话、切换连接及关闭旧隧道 |
| `Http2Session` / `Http3Session` | 协议握手、单连接复用、流额度及请求超时 |

配置修改遵循“校验版本 → 生成候选配置 → 应用运行状态 → 提交内存配置与版本 → 发布事件”。运行状态应用失败时不推进配置版本；监听变更失败会尝试恢复原监听。保存文件仍是显式操作。

`KernelControl` 的锁负责串行业务操作，`ControlApi` 在同一锁内取得操作结果和版本快照，实际 HTTP 响应写入在锁外执行。`ProxyRuntime` 只由控制入口访问；协议会话和流状态继续由所属 Netty EventLoop 串行处理。架构拆分不改变现有 API、配置格式或断线重连策略。
