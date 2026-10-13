# HTTP/2 与 HTTP/3 多路复用代理

Java 25 + Netty 4.2.18.Final。Flutter UI 称为「代理客户端」，Java ClientG 称为「代理内核」，Java Server 称为「代理服务端」。代理内核提供本地 HTTP 代理入口，支持保存多份连接配置并切换默认连接，每份配置选择 HTTP/2 或 HTTP/3；每个代理隧道使用独立的 CONNECT 流。

```text
浏览器/应用 -- 本地 TCP --> ClientG
                              ║ HTTP/3（QUIC/UDP）或 HTTP/2（TLS/TCP）
                              ║ 多个独立 CONNECT 流
                            Server -- TCP 连接 / UDP 报文 --> 目标
```

## 使用入口

- 桌面客户端：Flutter 源码位于 [ui/](ui/README.md)，与内核统一由本仓库管理。
- 已有发布目录：按下面的「发布目录启动与远程部署」启动，不需要 Maven。
- 从源码构建：安装 JDK 25、Maven 3.9，以及支持 `-addext` 的 OpenSSL（生成证书使用）。
- 配置直连网段：查看「直连规则」，通过管理接口修改并自动保存。

## 仓库结构

```text
network/
├── ClientG/      # Java 代理内核
├── Server/       # Java 代理服务端
├── ProxyCommon/  # Java 公共组件
├── ui/           # Flutter 桌面客户端
├── docs/         # 内核接口与构建文档
├── scripts/      # 内核构建、发布与统一提交脚本
└── pom.xml       # Maven 聚合项目
```

UI 与内核使用同一个 Git 仓库，Maven 和 Flutter 分别构建；`ui/` 不属于 Maven 模块。客户端开发、打包和测试命令见 [UI 说明](ui/README.md)。在仓库根目录执行 `sh ui/scripts/run-dev.sh` 可构建 JAR 并启动 macOS 开发界面，需要 Flutter、JDK 25、Maven 和 Xcode。

提交统一在仓库根目录按 [项目要求](AGENTS.md) 执行 `sh scripts/commit.sh`，该脚本只提交已暂存内容。UI 专属规范见 [ui/AGENTS.md](ui/AGENTS.md)。

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

本机初始化和发布脚本需要 Python 3，并通过管理 API 创建数据库；运行发布产物不需要 Python。

代理内核支持 GraalVM 25 AOT 构建：`GRAALVM_HOME=/实际路径/graalvm-25 sh scripts/build-native.sh`，生成无需 Java 运行时的本机程序。构建、动态库打包、元数据与协议验证见 [原生内核说明](docs/native-image.md)。

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
    ├── kernel.db
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
2. 通过客户端或管理 API，在各连接的 `config` 中把 `server.host` 改为服务端可访问的 IP 或域名。`server.port` 必须与服务端 `port` 一致。
3. 在服务端防火墙、安全组及必要的路由器端口转发中放行对应 **UDP** 端口，默认 `4433`。
4. 保持客户端 `username`、`password` 与服务端账号文件对应。使用脚本生成的证书时，保留 `tls.serverName=localhost` 和 `tls.ca=certs/server.crt`；连接地址与证书验证名称是两个独立配置。
5. 先启动服务端，再启动代理内核；通过管理接口调用 `/api/v1/proxy/start` 开启转发，然后将浏览器/应用的 HTTP 和 HTTPS 代理地址均设为 `127.0.0.1:8080`。本地代理入口使用 HTTP，HTTPS 网站通过 CONNECT 隧道访问。

每次打包生成默认账号 `client1` 的随机密码及有效期 365 天的自签名证书。客户端只需要公开证书，私钥保留在服务端。更换证书时需同步客户端信任证书及 `tls.serverName`，名称必须匹配新证书的 SAN；证书到期需要手动更新。客户端目录含访问凭证，只分发给获准使用代理的用户。

发布目录已被 Git 忽略。脚本拒绝覆盖已有目录；再次生成可使用 `sh scripts/package-release.sh /tmp/network-release-next`。升级现有部署时，停止两端进程，将新构建的两个 JAR 分别替换为 `server/server.jar` 和 `client/client.jar`，保留 SQLite 数据库、服务端配置和证书后重启；旧 JSON/PAC 配置不会自动迁移，需通过管理接口重新录入。不要混用不同次打包生成的密码或证书。

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

先完成 JAR 构建。以下脚本通过管理接口初始化独立的 `.local-h3/kernel.db`，生成随机密码和 localhost 自签名证书，不覆盖已有目录。需要 Python 3 和支持 `-addext` 的 OpenSSL。

```sh
sh scripts/create-local-config.sh
java --enable-native-access=ALL-UNNAMED -jar Server/target/Server-1.0-SNAPSHOT.jar .local-h3/server.properties
```

另开终端：

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web --db .local-h3/kernel.db
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
2. 运行代理服务端 `NettyServer` 和代理内核 `ClientApplication`，通过管理接口调用 `/api/v1/proxy/start` 开始转发后，再运行发送端。使用上面的本机配置时，工作目录设置为项目根目录，Program arguments 分别填写 `.local-h3/server.properties` 和 `--web --db .local-h3/kernel.db`；VM options 填写 `--enable-native-access=ALL-UNNAMED`。
3. 运行 `ClientG/src/test/java/com/blacicada/manual/ProxyHelloSender.java`。默认连接 `127.0.0.1:8080`，发送 `CONNECT 127.0.0.1:18080`，收到成功响应后发送 `hello world`。
4. 接收端控制台打印收到的数据并原样回显，发送端打印 `代理通信测试成功`。接收端保持监听，可重复运行发送端；测试结束后点击 Stop 停止接收端及代理进程。

发送端参数可覆盖为 `proxyHost proxyPort targetHost targetPort`；接收端参数为 `bindHost port`，也可直接修改类顶部的默认常量。目标地址由**代理服务端**访问：跨机器测试时填写服务端能访问的接收端 IP，并使接收端监听对应网卡地址。客户端直连列表应保持为空，确保此次测试经过 HTTP/3 服务端。

## 部署配置

服务端参考 `examples/server.properties`，相对路径以服务端配置目录为基准。内核 API 请求体参考 [examples/config-request.json](examples/config-request.json)。内核默认使用可执行程序旁的 `kernel.db`：JAR 模式与 JAR 同目录，原生模式与原生程序同目录；IDE 运行使用编译输出目录。可通过 `--db` 指定路径，证书相对路径以数据库目录为基准。数据库不存在时自动建库，旧 JSON/PAC 文件不读取、不迁移、不删除。

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
| `local.routesInline` | 直连域名/IP/CIDR 规则文本，存入 SQLite；默认空规则 |
| `local.routesOverrides` | 精确目标强制 proxy/direct，每行一条；数据库按目标逐行保存 |
| `local.routingMode` | rules（默认）、direct 或 proxy |

两端均支持：

- `connectTimeoutMillis`：DNS/连接或 CONNECT 握手的等待限制，默认 10000 毫秒。本地初始请求整体等待限制为其两倍。
- `idleTimeoutSeconds`：共享 QUIC 连接空闲超时，默认 300 秒。
- `maxStreams`：流并发上限，默认 1024。客户端计入正在等待建立的流，超过本地上限的请求直接失败，不影响已有隧道。服务端 QUIC 流额度暂时耗尽时，客户端等待 MAX_STREAMS 更新后继续创建流，等待最长为 `connectTimeoutMillis`，不会为此断开共享连接。 HTTP/2 同样遵守服务端发布的流额度。TUN 的每个 UDP 关联也占用一条流，双向空闲 60 秒后回收；持续发送的 UDP 流量仍会占用额度。提高容量需要同时检查客户端与服务端的 `maxStreams`，只修改一侧仍受另一侧限制。 HTTP/2 服务端的重置帧限制随并发上限调整（每 30 秒至少 200 次、且不低于 `maxStreams`），允许一批隧道关闭后继续复用主连接。

远程部署需要开放服务端 UDP 端口。自签名部署将服务器证书配置为客户端 `tls.ca`；公开证书使用正常的信任链。程序不会跳过证书或主机名验证，也不启用 TLS 0-RTT。

## 多客户端与独立账号

UDP 转发先解析目标地址，再创建对应原生 IPv4 或 IPv6 套接字；macOS 直连出口也使用对应地址族的接口绑定选项，避免双栈 UDP 通配端口与 IPv4 应用重叠造成回包丢失。

单个目标的 CONNECT 失败、等待超时或本地额度耗尽只记录在访问结果及运行日志中，不显示为整个代理连接故障。运行日志包含目标、原始 TCP/UDP 协议及直连/代理路由；本地额度耗尽另附占用与上限。概览仍提示服务端连接和认证错误。

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

通过管理接口修改代理内核所选连接的 `config`：

```json
{"username":"client1","password":"替换为客户端1的随机长密码"}
```

客户端 2 填写 `username=client2` 及对应密码。两者连接相同的 `server.host` 和 `server.port`，使用同一份服务端公开证书。不要分发服务端私钥或完整账号文件。不同机器都可使用本地端口 `8080`；同机运行多个客户端时，每个实例使用独立目录及不同本地 `port`。

每个 CONNECT 流都会验证账号和密码，认证信息由 TLS 加密传输，不记录到日志。启用 `usersFile` 后，即使仍配置服务端 `password`，也不再接受旧的共享密码认证；未配置 `usersFile` 时保持旧模式，客户端省略 `username`，两端 `password` 相同即可。

新增、删除账号或修改密码后重启服务端；代理内核在 Web 模式下修改连接账号配置后立即重建当前会话，通过接口修改后立即生效。重启服务端会断开所有现有客户端连接，后续请求按需重连。当前不提供账号热更新、每账号带宽限制或每账号连接总数限制。

新生成的发布目录默认启用账号模式，创建随机密码的 `client1` 并写入配套客户端配置。既有发布目录的凭证不会因更新 JAR 自动切换认证模式。

## 直连规则（域名、IP 与网段）

直连规则统一保存在 SQLite，通过 `PUT /api/v1/routing/direct-rules` 修改，或通过路由 JSON 导入。规则命中时由内核直接连接目标，未命中时走默认代理；全局模式和精确目标规则的优先级见 [Web API](docs/web-api.md)。浏览器仍配置普通 HTTP 代理。

规则为空或只有注释时不会自动添加内网直连规则。按需编辑以下规则文本，每行一条：


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
- 非法 CIDR 会报告规则行号并拒绝修改。调用直连规则更新或导入接口立即应用：关闭直连与代理之间发生变化的业务连接，路由结果未变的连接保持。无需重启服务端。

路由导入导出示例见 [examples/routing.json](examples/routing.json)，导入前请调整其中的默认连接 ID。

### 域名如何匹配网段

1. 先检查域名规则，命中则客户端直接连接。
2. 域名未命中且列表中有 IP/CIDR 规则时，客户端异步解析域名，检查返回的 IP 地址。
3. 选择解析结果中第一个命中规则的 IP 并直接连接该 IP，避免再次解析改变目标。
4. 没有命中 IP 或本地 DNS 解析失败时，通过 HTTP/3 转发原域名，由服务端解析并连接。

因此添加网段规则后，未命中域名规则的域名也可能在客户端产生 DNS 查询。直连连接失败会返回错误，不会自动改走远程代理。直连时 `127.0.0.1` 指客户端自身；走代理时该地址指服务端自身。

更新规则时，内核遍历已有浏览器连接，使用各连接自身保存的目标、地址和路由状态重新判断；不维护额外的规则到会话映射。新增直连规则会关闭受影响的代理流，移除直连规则会关闭不再匹配的直连连接；共享 HTTP/2、HTTP/3 主连接继续复用。重叠规则仍使路由结果保持不变时不关闭连接，注释、顺序、重复项和 CIDR 主机位变化也不会中断连接。

正在等待 DNS 或代理流额度的请求同样受规则更新约束。已有直连优先按实际连接 IP 判断；代理域名缺少本地地址记录时，新增网段规则需要异步 DNS 完成后才能确认是否关闭。DNS 回调始终使用最新规则，解析失败时按原有规则选择逻辑走代理。受影响连接不会迁移或重放数据，由浏览器或应用重新发起请求；下载可能需要重试。

## 常见问题

| 现象 | 检查方式 |
| --- | --- |
| 启动提示找不到配置、证书或私钥 | 使用启动脚本；服务端指定 properties 路径，代理内核使用 `--web --db /数据目录/kernel.db`；服务端相对路径基于配置文件目录，内核基于数据库目录，复制部署时是否保留 `certs/` |
| 启动提示端口占用 | 停止旧进程或修改 `port`；服务端修改端口后同步客户端 `server.port`，客户端修改端口后同步浏览器代理设置 |
| 客户端启动成功，但无法访问网站 | 共享 QUIC 连接按需建立，启动成功不代表已连接服务端；检查 `server.host`、端口以及 UDP 防火墙规则 |
| TLS 握手或证书校验失败 | 检查证书有效期、`tls.ca` 是否信任当前服务端证书，以及 `tls.serverName` 是否匹配证书 SAN |
| 返回 502 | 查看客户端和服务端终端日志；检查账号和密码、目标 DNS 和目标 TCP 可达性。直连目标由客户端访问，代理目标由服务端访问 |
| 返回 504 | 初始请求建立超时；检查网络和服务端可达性，再按需调整 `connectTimeoutMillis` |
| 路由修改没有生效 | 使用管理接口查询当前规则和全局模式；外部 PAC 文件不参与路由 |
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
- HTTP/2 与 HTTP/3 由连接配置明确选择，不自动降级。UDP 目标通过下述项目专用 CONNECT 封装转发；macOS TUN 接入见下文。尚未实现 SOCKS5、标准 CONNECT-UDP 或 QUIC DATAGRAM。
- 新旧客户端/服务端的线协议不兼容，必须成对升级。旧的 `key`、序号与字节映射实现已移除。

### UDP 本地接入与可靠流封装

ClientG 和 Server 必须使用本次支持 UDP 的版本。适配器连接现有本地 HTTP 代理端口（默认 `127.0.0.1:8080`），发送：

```http
CONNECT 目标主机:目标端口 HTTP/1.1
Host: 目标主机:目标端口
x-network-transport: udp

```

实际请求行和请求头以 `\r\n` 分隔，以 `\r\n\r\n` 结束。IPv6 目标使用 `[地址]:端口`。一条 CONNECT 关联固定一个目标，不在报文中重复携带地址；不同来源或目标应建立独立关联。

成功响应为 `200`，必须包含唯一的 `x-network-transport: udp`。代理模式下，同一标识在远端 HTTP/2、HTTP/3 CONNECT 请求与成功响应中传递，仍使用现有认证和 TLS 校验。未确认 UDP 的响应视为失败，不切换成 TCP 或其他协议。未知、重复的标识返回 `400`；无此标识的 CONNECT 继续表示 TCP。

握手之后，两端每个 UDP 报文均表示为：

```text
两字节无符号大端长度 N | N 字节 UDP 负载
```

- 长度不包含前缀，范围为 `0..65507`，包括真实的空 UDP 报文。IPv4、IPv6 使用相同上限，不支持 UDP jumbogram。
- 字节流可能拆包或合包；必须按长度读取完整报文，不能将一次读取或一个 HTTP DATA 帧当作一条报文。目标回包使用相同格式，每个关联允许多个回包。
- Server 为每个关联创建独立 UDP 套接字，固定发送目标，只接受该目标地址和端口的回包。直连时由 ClientG 创建该套接字，沿用当前直连规则及路由模式。
- 关闭、半关闭、畸形报文或连续 60 秒没有完整报文活动会结束关联。规则导致路由变化或切换代理连接时，沿用现有业务连接清理机制。后续发送需要重新建立关联。
- UDP 负载经过 HTTP/2 或 HTTP/3 的可靠 DATA 流，因此丢包会等待重传。最终 UDP 网络仍可能丢包；`200` 只表示关联准备好，不表示目标在线或报文已送达。
- 流量统计只计 UDP 负载，不计两字节前缀；访问记录使用 `CONNECT-UDP` 标签表示此项目专用接入，实际 HTTP 方法仍为 `CONNECT`。直连关联的 `protocol` 为 `udp`，代理关联为 `http2` 或 `http3`。

下面的 Python 3 示例通过已运行的 ClientG 向本机 UDP 回显服务发送报文；先将 `target` 改为实际测试目标：

```python
import socket
import struct

target = "127.0.0.1:9999"
payload = b"hello udp"

with socket.create_connection(("127.0.0.1", 8080), timeout=5) as connection:
    connection.sendall((f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n"
                        "x-network-transport: udp\r\n\r\n").encode("ascii"))
    stream = connection.makefile("rb")
    status = stream.readline()
    headers = []
    while (line := stream.readline()) != b"\r\n":
        if not line:
            raise RuntimeError("UDP 握手提前结束")
        headers.append(line.strip().lower())
    if not status.startswith(b"HTTP/1.1 200 ") or headers.count(b"x-network-transport: udp") != 1:
        raise RuntimeError("UDP 握手失败")
    connection.sendall(struct.pack("!H", len(payload)) + payload)
    prefix = stream.read(2)
    if len(prefix) != 2:
        raise RuntimeError("UDP 关联已关闭")
    length = struct.unpack("!H", prefix)[0]
    reply = stream.read(length)
    if len(reply) != length:
        raise RuntimeError("UDP 回包不完整")
    print("UDP 回包：", reply)
    stream.close()
```

普通应用仅设置 HTTP 系统代理不会自动接入其 UDP 流量；macOS 客户端可开启下面的虚拟网卡模式。

## 源码位置

- `ClientG/.../proxy`：本地 HTTP 入口、业务会话、共享协议会话与请求转发；直连规则位于 `config` 包。
- `Server/.../h3`：HTTP/3 监听、CONNECT 认证与目标连接。
- `ProxyCommon/.../h3`：配置、地址解析、HTTP/3 数据适配与双向转发。

旧协议 Handler、字节映射编解码、数据库实验资源和根目录 `src` 下的早期实验代码已清理。现有单元测试、HTTP/3 集成测试及两个可直接运行的 hello world 测试类均保留；IDEA 运行配置位于 `.run/`。

### CONNECT 超时与连接恢复

CONNECT 超时后会取消对应请求流的双向传输。若整个等待期间 QUIC 有发包却完全没有回包，客户端会记录诊断日志并关闭疑似失效的共享连接，让后续请求重新连接。此时该连接上的已有隧道也会结束，应用需要重新发起请求；代理不会重放已发送的数据。

若 QUIC 仍正常回包，仅目标连接慢或流额度耗尽，不会因此关闭共享连接。超时日志包含目标地址或流额度，以及连接 ID；可结合服务端的 CONNECT 失败日志定位。

## Web 管理接口（唯一内核入口）

代理客户端通过本机 HTTP + JSON 操作代理内核，通过 SSE 订阅状态、日志与诊断结果。支持连接配置增删改、切换连接、启动/停止转发和热更新；UI 关闭后内核继续运行。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web --db /数据目录/kernel.db --port 9090
```

代理内核只接受 `--web` 入口，不再接受无参数启动或直接传入配置文件。启动脚本和 IDEA 配置也使用 Web 模式。启动后代理转发处于停止状态，UI 调用 `/api/v1/proxy/start` 开始转发。管理接口固定监听 `127.0.0.1`，默认发现文件为数据库目录下的 `run/control.json`，包含管理地址和随机令牌；仅当前用户可读写。用 `--port 0` 自动分配管理端口。所有接口要求 `Authorization: Bearer <token>`，令牌不要放入 URL。

详细接口、请求示例、错误码、热更新规则和 Flutter 接入流程见 [Web 管理接口文档](docs/web-api.md)。修改本地代理监听地址/端口会立即重启转发并断开全部旧连接；管理接口保持运行。修改成功后自动保存到 SQLite，重启后恢复；不再提供手动保存。


## 多连接配置与 HTTP/2

API 请求体示例见 [examples/config-request.json](examples/config-request.json)，可提交到 `PUT /api/v1/config`。内核通过 SQLite 持久化；在每份连接的 `config` 中设置 `"protocol":"http2"` 或 `"protocol":"http3"`。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web
```

运行前替换示例中的服务器地址、账号和密码。示例默认使用系统信任证书；私有 CA 或自签名证书需要在每份连接的 `config` 中设置 `tls.ca`，且 `tls.serverName` 必须匹配证书。

- `version`：目前固定为 `1`。
- `local`：本地监听、直连规则与本地请求建立超时；规则只来自数据库中的当前快照。
- `connections`：0 至 128 份配置，每份包含稳定的 `id`、显示名称 `name`、连接参数 `config`。
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

配置修改遵循“校验版本 → 生成候选配置 → 写入未提交的 SQLite 事务 → 应用运行状态 → 提交数据库及内存版本 → 发布事件”。应用或数据库提交失败会回滚；运行配置恢复失败时停止代理。事务恢复失败后需重启内核。已断开的业务连接无法恢复。

`KernelControl` 的锁负责串行业务操作，`ControlApi` 在同一锁内取得操作结果和版本快照，实际 HTTP 响应写入在锁外执行。`ProxyRuntime` 只由控制入口访问；协议会话和流状态继续由所属 Netty EventLoop 串行处理。SQLite 版本移除了手动保存和文件重载接口；协议与断线重连策略保持。

### 包与复用边界

- `ClientG/com.blacicada.proxy`：本地代理入口、默认会话路由与 HTTP/2、HTTP/3 会话；这些组件不再放在只表示 HTTP/3 的 `h3` 包中。
- `ClientG/com.blacicada.config`：内核配置及直连规则。规则快照统一由 `DirectRoutes.load` 构造，配置验证、启动、热更新共用该实现。
- `ProxyCommon/com.blacicada.common`：两端、两种协议实际共用的目标地址、配置、认证、转发与传输辅助代码。协议帧及 QUIC 专用处理仍放在 `common.h2`、`common.h3`。
- `ClientG/com.blacicada.io.PrivateFiles`：数据库和管理令牌文件共用私有权限控制，发现文件继续原子写入。

路由查询和诊断使用当前配置快照。SQLite 是唯一配置存储；不要直接修改运行中的数据库。

保留 `ProxySession`、会话工厂和生命周期管理器，因为它们已有多种协议实现、多个调用点或独立资源管理职责。删除未使用的旧启动等待方法、配置 upsert、重复密码保留分支和过期重载，不为未来需求保留兼容空壳。

## 路由导入导出

`GET /api/v1/routing/export` 返回带版本号的路由文档，把响应中的 `data` 保存为 UTF-8 JSON。`POST /api/v1/routing/import` 接收该文档并要求 `If-Match`，完整替换模式、默认连接、直连规则和精确目标规则，校验及保存作为一次修改完成。默认连接 ID 必须已存在，导入不创建连接、不包含凭据。格式、错误和客户端接入说明见 [Web API](docs/web-api.md#sqlite-与路由导入导出)。

数据库包含代理密码且未加密，仅应由当前用户访问。同一数据库只能由一个内核实例打开；损坏或未知版本的数据库不会自动重置。日志、活动连接、事件和诊断结果不入库；`control.json` 继续供客户端发现正在运行的内核。备份前先停止内核，保留数据库及配套证书。


### macOS 虚拟网卡模式

概览页的「虚拟网卡模式」开关在代理运行后可用。系统管理员授权后，独立辅助进程创建 `utun`，将经过该接口的 TCP/UDP 报文交给 Outline SDK，再通过本机 CONNECT 交给 Java 内核。TCP 沿用原有隧道；UDP 使用上面的长度前缀封装，远端仍采用配置指定的 HTTP/2 或 HTTP/3 可靠流。

直连流量也经过 Java 内核，继续统计流量与记录访问。进入 TUN、目标端口为 53 的 TCP/UDP 查询自动由 Java DNS 模块处理，使用系统当前配置的 DNS 上游并返回真实响应，不修改系统 DNS、不提供 Fake-IP。上游读取复用 Netty 的系统 DNS 提供器，按查询域名选择系统解析器；查询绑定真实出口，不再次进入 TUN。单个上游最长等待 3 秒，失败后依次尝试系统提供的其他地址，最多尝试 4 个；全部失败返回 SERVFAIL。UDP 的截断响应原样返回，由应用按标准重试 TCP。

内核从成功回答的 A/AAAA 与 CNAME 链建立 IP 到原查询域名的关联，按链上最短 TTL 过期，同一 IP 使用最新一次有效回答的域名。新建 TUN 业务连接时读取关联，用于目标展示、访问记录和域名规则；出站仍连接应用请求的原始 IP，不重新解析关联域名或改写代理目标。路由优先级为全局模式、原始 IP 精确规则、关联域名精确规则，再判断域名后缀和 IP/CIDR 直连规则。已有连接固定使用建立时取得的域名，后续关联变化不重命名已有连接；规则更新仍按原有机制关闭路由发生变化的连接。

域名关联最多保留 8192 个地址，仅存内存，重启或重建代理监听后重新积累。完整且成功、无请求附加选项的普通 DNS 回答可按 TTL 缓存，最多 1024 条，每条不超过 4096 字节；缓存命中也更新最新域名关联，但不延长原回答有效期。DNS 通道只计流量，不作为业务隧道或访问记录展示。

DoH、DoT、DoQ 等非 53 端口流量继续按普通连接转发，不解密或降级。绕过 TUN 的 DNS、应用已有解析缓存、直接访问 IP 等情况无法保证域名关联；无有效关联时按 IP/CIDR 与全局模式处理。多个域名共用 IP 时可能误关联，这是本版明确接受的限制。默认网关及本机地址仍按既有路由放行，系统 DNS 指向这些地址时可能绕过 TUN，本次不改变这部分路由。

启用前会重建 Java 代理的现有连接，并将内核的 TCP、UDP、DNS 和远端代理连接绑定到真实出口接口，避免再次进入 TUN。接管前为绑定出口准备 IPv4/IPv6 作用域默认路由，复用符合当前网关的已有条目；仅管理本次新增条目。停用时先移除本次添加的路由并关闭 utun，再恢复普通内核出口；启停均可能中断下载等现有连接。TUN 工作期间可以切换规则与代理节点，修改本地监听地址/端口或重启代理前需要先关闭 TUN。

首次开启会请求管理员授权，将辅助程序安装到 `/Library/PrivilegedHelperTools/com.blacicada.network-tun/network-tun`，并注册 `/Library/LaunchDaemons/com.blacicada.network-tun.plist`。以后开关虚拟网卡不再重复输入密码；客户端与已安装程序的 SHA-256 不同时，更新辅助程序需要再次授权。系统服务开机待命，但不会自动开启 TUN，也不保存管理员密码。

服务通过仅限授权用户访问的 Unix 套接字通信，核验系统提供的对端 UID/PID。只允许启动固定的已安装程序，不接受任意命令、环境变量或路由参数。一次安装只授权一个本机用户；辅助程序和服务配置由 root 持有，普通用户不可修改。每次会话单独创建转发进程及路由清理子进程。管理员转发进程退出或被强制结束时，清理子进程撤销本次新增的作用域路由。授权期间关闭开关会撤销本次启动标识，迟到的启动请求不能接管路由。关闭开关、停止代理、客户端进程退出、管理连接丢失或网络出口改变都会触发清理；切换 Wi-Fi、网卡或网关后需手动重新开启。卸载和更新在有活动会话时会被拒绝，需先关闭 TUN。

移除系统辅助服务时，先关闭虚拟网卡，再进入「设置 → 虚拟网卡辅助服务」，点击「卸载系统辅助服务」，确认后完成管理员授权。面板显示安装状态，也可手动刷新；卸载只移除该服务的固定文件，不清理用户配置、证书和访问记录。下次开启虚拟网卡会重新请求安装授权。也可以执行下面的命令：

```sh
sudo /Library/PrivilegedHelperTools/com.blacicada.network-tun/network-tun --remove-service
```


当前边界：

- 需要 macOS 的可用 IPv4 主网络接口；IPv4 和 IPv6 出站均绑定此接口，暂不支持仅 IPv6 的主网络、多出口或与其他 VPN 叠加。IPv6 访问还需真实出口支持 IPv6。
- 使用细分默认路由，并细分主网卡直连网段；回环、本机地址、默认网关、链路本地地址、已有更精确的系统路由及应用显式绑定接口的流量可能不进入 TUN。此功能覆盖路由进入虚拟网卡的 TCP/UDP，不是对所有系统报文的强制拦截。
- 不支持 ICMP、组播或非 TCP/UDP 协议，不修改系统 DNS 设置，也不提供 DNS 防泄漏保证。系统发往普通 DNS 地址的 UDP/TCP 请求进入 TUN 时，沿用同样的转发路径。
- 退出后恢复正常系统路由，不提供断网保护（kill switch）。不会覆盖已有的同前缀路由；冲突或中途失败会清理本进程已添加的路由并报错。

构建需要 Java 25、Flutter、Go 1.25 或更高版本以及 Xcode Command Line Tools 的 C 编译器。`TunBridge/go.mod` 固定 Outline SDK `v0.0.23`，通过其 `lwip2transport` 接口适配 TCP/UDP；该版本间接依赖 `go-tun2socks v1.16.11` 和 lwIP。仓库在 `TunBridge/patches/` 保留最小补丁：使用双栈协议控制块、修复空 UDP 回包并检查发送错误、将 UDP 回包与协议栈输入串行处理。构建脚本只在临时副本应用补丁，使用临时 Go 模块替换，不修改全局 Go 缓存或项目 `go.mod`；依赖版本变化或补丁不能准确应用时构建失败，需重新复核。第三方许可证位于 `TunBridge/licenses/`，打包时一并复制。

```sh
# 使用相同补丁运行竞态检查与原始 IPv4/IPv6 TCP、UDP、空报文测试
sh scripts/build-tun.sh --test

# 单独构建辅助进程（不会执行 Java AOT）
sh scripts/build-tun.sh

# 开发运行，同时构建 JAR 和辅助进程
sh ui/scripts/run-dev.sh

# 打包内置 JAR、Java 运行时、辅助进程的 macOS 应用
sh ui/scripts/package-macos-jar.sh /目标目录/Network-JAR.app
```

已安装系统服务后，可执行 `python3 scripts/check-tun-service.py /应用路径/Contents/Resources/proxy/network-tun`，校验权限、版本一致性和连续两次无提权调用；验证在启动标识校验处中止，不创建 TUN 或改动路由。

可通过 `GO`、`FLUTTER`、`JDK_HOME` 指定本机工具路径；日常验证使用 JAR。实际 utun 创建、路由接管及恢复需要在本机管理员授权后联调，普通单元测试不会修改系统路由。


本轮验证记录（2026-10-11）：Java 全量测试 162 项通过；Flutter 全量测试 98 项通过、14 项按原有环境条件跳过，静态分析通过；Go 在应用依赖补丁后通过竞态检查，覆盖原始 IPv4/IPv6 TCP、UDP 及空 UDP 回包。本机管理员授权联调已验证 utun 接管、IPv4 TCP/HTTPS、UDP/DNS、内核关联记录和正常退出后的路由恢复。强制退出清理子进程随后加入，最后一轮故障联调因系统授权超时而未执行，该异常退出路径仍待实机验证。公网 IPv6 与真实网络切换也尚未逐项联调。

2026-10-12 补充验证：访问记录状态筛选在数据库中先过滤后分页，Java 全量 163 项、Flutter 全量 98 项通过（14 项原有条件跳过），静态分析通过。辅助服务通过真实管理员授权完成安装，校验了 root 所有的安装文件和仅授权用户可访问的套接字，并连续两次通过普通用户启动会话进程；两次均在测试用失效标识处中止，没有接管路由。新版服务模式的真实 TUN 连续开关及服务异常退出恢复仍待实机验证，不能将上述 IPC 检查视为这两项验证完成。
