# 代理发布目录

此目录不需要 Maven 或项目源码，安装 JDK 25 后即可启动。可以分别复制 `server/` 和 `client/` 到对应机器，保留各自内部目录结构。

```text
release/
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

## 命令行启动

macOS / Linux，在此发布目录下运行：

```sh
./server/start.sh
```

另开终端：

```sh
./client/start.sh
```

脚本支持从任意工作目录调用，也支持 `JAVA_HOME`。Windows 在此目录的命令提示符中分别执行 `server\start.cmd`、`client\start.cmd`。启动脚本在前台运行，按 Ctrl+C 停止。

也可以直接使用 Java 命令（以下命令在发布目录执行）：

```sh
java --enable-native-access=ALL-UNNAMED -jar server/server.jar server/config/server.properties
java --enable-native-access=ALL-UNNAMED -jar client/client.jar --web --config client/config/kernel.json
```

## Web 管理模式

Flutter 代理客户端可通过本机 Web 接口控制代理内核，在发布目录执行：

```sh
java --enable-native-access=ALL-UNNAMED -jar client/client.jar --web --config client/config/kernel.json --port 9090
```

此模式初始不启动转发，由 UI 调用 `/api/v1/proxy/start`。管理接口固定监听 `127.0.0.1`，发现文件位于 `client/config/run/control.json`，包含地址和访问令牌；所有业务请求要求 `Authorization: Bearer <token>`。UI 关闭后内核继续运行，退出使用 `/api/v1/kernel/shutdown`。详细接口见 [Web 管理接口](client/WEB-API.md)。

规则更新只影响新请求；切换默认连接或修改当前连接参数立即关闭旧代理隧道；修改本地监听地址或端口立即重启转发并关闭全部旧连接。配置应用后需显式保存才会在进程重启后保留。`client/start.sh`、`client/start.cmd` 与 `client/background.sh` 均启动 Web 管理接口，不自动开启代理转发。

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

## 配置

- 默认服务端监听 UDP `4433`，客户端提供 `127.0.0.1:8080` HTTP 代理。
- 默认客户端连接本机服务端，可以直接进行本机测试。远程部署时，在 `client/config/kernel.json` 中将对应连接 `config` 下的 `server.host` 改为服务端 IP 或域名，并开放服务端 UDP `4433`。
- 每次打包生成默认账号 `client1` 的随机密码和有效期 365 天的自签名证书。客户端仅包含公开证书，服务端私钥仅位于 `server/certs/server.key`。
- 默认 `tls.serverName=localhost` 与此次生成证书的身份匹配，即使修改连接地址，也应保留该值；若换用域名证书，需同步修改 `tls.serverName` 和客户端信任证书。证书和主机名校验始终启用。
- 更改密码时，修改服务端 `config/users.properties` 中该账号的密码，并同步对应客户端的 `password`。
- `client/config/pac.txt` 默认无直连规则，全部经过 HTTP/3 服务端。每行可填写直连域名、单个 IP 或 CIDR 网段，例如 `192.168.0.0/16`、`fd00::/8`，修改后调用规则重载接口。域名未命中规则时，若存在 IP/CIDR 规则，会异步解析并直连命中的 IP；无匹配或本地解析失败则走远程代理。
- 配置中的相对文件路径以配置文件所在目录为基准。
- 浏览器使用 HTTP/HTTPS 代理 `127.0.0.1:8080`。两端通信使用 HTTP/3，目标连接为 TCP。

目录内包含实际运行凭证，请仅将客户端目录分发给获准使用代理的用户。

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

新增、删除账号或修改密码后重启服务端；客户端修改账号配置后重启自身。重启服务端会断开所有现有客户端连接，后续请求按需重连。当前不提供账号热更新、每账号带宽限制或每账号连接总数限制。

新生成的发布目录默认启用账号模式，创建随机密码的 `client1` 并写入配套客户端配置。既有发布目录的凭证不会因更新 JAR 自动切换认证模式。

## 配置直连网段

编辑 `client/config/pac.txt`，UTF-8 编码，每行一条。按需要选用以下规则：

```text
# 域名自身及所有子域名
example.com

# 单个 IP
192.168.1.10

# IPv4 内网和回环网段
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
127.0.0.0/8

# IPv6 回环和唯一本地地址
::1/128
fc00::/7
```

例如只让 `192.168.1.*` 直连，填写 `192.168.1.0/24`；`192.168.0.0/16` 覆盖整个 `192.168.*.*`。前缀长度越大，范围越小；IPv4 支持 0–32，IPv6 支持 0–128。`0.0.0.0/0` 和 `::/0` 分别匹配全部 IPv4 和 IPv6 地址。

空行和 `#` 注释会被忽略，也可写行尾注释。不支持 `*.example.com`、URL、端口、`192.168.*.*` 或起止 IP 范围。域名不区分大小写。所有条目均为直连规则，没有反向规则。文件为空或不存在时全部走远程代理，不会自动添加内网规则。

可调用 `/api/v1/routing/reload` 重载文件规则，无需重启服务端。非法 CIDR 会提示文件、行号并阻止启动。规则路径由代理内核配置 `local.routesFile` 决定（默认 `pac.txt`），相对于 `client/config/kernel.json` 所在目录。

域名先匹配域名规则；未命中且存在 IP/CIDR 规则时，客户端异步解析 DNS，选取第一个命中的 IP 直连。没有命中或本地 DNS 失败时转交服务端解析原域名。添加网段规则会增加客户端 DNS 查询；命中规则但直连失败时不会自动回退代理。直连的回环地址指客户端自身，代理的回环地址指服务端自身。

此文件是客户端的直连列表，不是浏览器的 JavaScript PAC 脚本，不要将它填入浏览器的自动代理配置 URL。

## 验证与排查

启动两端并通过 `/api/v1/proxy/start` 开启代理转发后，在客户端机器执行：

```sh
curl --noproxy "" --proxy http://127.0.0.1:8080 http://example.com/
curl --noproxy "" --proxy http://127.0.0.1:8080 https://example.com/
```

这些命令需要目标网站可达。`--noproxy ""` 用于避免环境变量 `NO_PROXY` 让 curl 绕过本地代理。

| 现象 | 检查项 |
| --- | --- |
| Java 无法启动 | `java -version` 是否为 JDK 25；`JAVA_HOME` 是否指向正确的 JDK |
| 端口被占用 | 停止旧进程，或修改对应配置端口并同步客户端/浏览器设置 |
| 找不到证书或配置 | 保留目录结构，配置内相对路径以 properties 文件目录为基准 |
| 客户端启动后请求失败 | 连接服务端按需发生；检查 `server.host`、`server.port`、服务端进程和 UDP 端口放行情况 |
| TLS 校验失败 | 检查证书有效期、客户端 `tls.ca` 与 `tls.serverName` 是否对应当前服务端证书 |
| 502 | 查看两端终端日志，检查账号和密码、目标 DNS 和目标 TCP 可达性 |
| 504 | 请求建立超时，先检查网络，再按需调整 `connectTimeoutMillis` |
| 网段规则不生效 | 检查实际 `routesFile` 路径，调用规则重载接口并建立新连接 |

## 更新与运行边界

升级时停止两端，分别替换 `server/server.jar` 和 `client/client.jar`，保留配置、PAC 与证书，再重新启动。不同次打包会生成不同密码和证书，不要混用；证书到期需要手动更新，并同步客户端信任配置。

两端默认 `connectTimeoutMillis=10000`、`idleTimeoutSeconds=300`、`maxStreams=256`。配置在启动时读取；内核通过 Web 接口修改并保存，服务端修改后重启。服务端更改端口、密码或证书时，需要同步客户端相关配置。

客户端入口为 HTTP/1.1 代理；HTTPS 使用 CONNECT 隧道。客户端到服务端使用单条 QUIC/HTTP/3 连接复用多个流，服务端到目标使用 TCP。连接配置也可显式选择 HTTP/2（TCP + TLS），服务端需设置 `protocols=http3,http2` 并放行相应 TCP 端口。两种协议不会自动回退。不支持 SOCKS5 或 UDP 目标。共享连接断开会结束现有隧道，后续请求按需重新连接，不会恢复已中断的 TCP 会话。

### CONNECT 超时与连接恢复

CONNECT 超时后会取消对应请求流的双向传输。若整个等待期间 QUIC 有发包却完全没有回包，客户端会记录诊断日志并关闭疑似失效的共享连接，让后续请求重新连接。此时该连接上的已有隧道也会结束，应用需要重新发起请求；代理不会重放已发送的数据。

若 QUIC 仍正常回包，仅目标连接慢或流额度耗尽，不会因此关闭共享连接。超时日志包含目标地址或流额度，以及连接 ID；可结合服务端的 CONNECT 失败日志定位。

### HTTP/2 隧道建立超时诊断

HTTP/2 超时日志按实际阶段分别显示“等待 HTTP/2 流额度”“创建 HTTP/2 流”“发送 HTTP/2 CONNECT”或“等待 HTTP/2 CONNECT 响应”。日志包含目标、连接 ID、流 ID、本地与服务端地址、对端并发上限、本连接占用、排队数量、当前阶段耗时和总等待时间。未创建流时，流 ID 显示“未分配”。

额度占用包含已预留但尚未完成创建的流；排队数量包含当前仍等待额度的请求。额度等待、流创建、请求发送和响应等待共用原有的 `connectTimeoutMillis` 预算，切换阶段不会重新计时。进入响应等待只表示本地写入完成，不证明服务端已收到或处理 CONNECT。

两端日志里的连接 ID 是各自本地的 Channel ID，不能直接按相同值匹配。应结合连接地址、端口、时间及 HTTP/2 流 ID 对照。该诊断改进不会仅因某个请求超时就重建共享连接，也不代表已经确定超时根因。
