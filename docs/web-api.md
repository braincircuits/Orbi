# 代理内核 Web 管理接口 v1

Flutter UI（代理客户端）使用此接口管理 Java 代理内核；接口不在代理服务端提供。代理内核本地代理端口负责浏览器流量，管理端口负责配置和状态。

## 启动与生命周期

代理内核只有 Web 管理入口。必须使用 `--web` 启动，不支持无参数启动、直接传入配置文件路径或旧管道模式。发布脚本也遵循这一行为。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar \
  --web --config kernel.json --port 9090
```

发布目录中将 JAR 路径换成 `client.jar`，配置路径换成 `config/kernel.json`。

| 参数 | 含义 |
| --- | --- |
| `--config` | 读取及保存的 JSON 文件，默认工作目录下的 `kernel.json`；不存在时以空配置启动 |
| `--port` | 本机管理端口，默认 9090；0 表示自动分配 |
| `--endpoint-file` | 管理连接信息文件，默认配置文件目录下的 `run/control.json` |
| `--token-file` | 可选，从文件读取至少 32 字符的管理令牌；默认每次启动生成随机令牌 |
| `--allow-origin` | 可重复指定网页 Origin，例如 `http://localhost:3000`；默认不允许其他网页来源 |

管理接口固定监听 `127.0.0.1`。发现文件包含 `url`、`token`、`pid`、`apiVersion`，在支持 POSIX 权限的平台设置为 `600`，正常退出时清理。请将自定义发现文件加入 Git 忽略规则。令牌不写入日志，也不通过查询接口返回。持有令牌的同机程序能修改代理配置，应妥善保管发现文件。

Web 模式启动后不会自动开启代理转发。UI 先读取配置，再调用 `/proxy/start`。UI 关闭、HTTP 请求断开、SSE 订阅断开、标准输入关闭均不停止内核；退出必须显式调用 `/kernel/shutdown` 或由进程管理器终止。`/proxy/stop` 只停止转发，管理接口仍可使用。未保存的配置在内核退出后丢失。

管理端口、管理令牌和 CORS 白名单属于启动参数，修改需要重启内核进程。它们不能通过代理配置热更新。此设计使 UI 可以使用稳定管理地址恢复和操作转发。

## 请求与返回

所有业务接口以 `/api/v1` 开头，携带：

```http
Authorization: Bearer <从发现文件读取的 token>
Content-Type: application/json
```

浏览器预检 `OPTIONS` 不要求令牌，但必须来自允许的 Origin。Flutter 桌面 HTTP 客户端通常不发送 Origin，无需设置白名单。Flutter Web 需要配置准确的 Origin；禁止通配来源。SSE 也要求 Authorization，网页应使用能设置请求头的流式 HTTP 客户端。

成功响应示例：

```json
{
  "revision": 3,
  "savedRevision": 2,
  "dirty": true,
  "requiresProxyRestart": false,
  "requestId": "请求标识",
  "data": {}
}
```

`revision` 是当前内存配置版本，`savedRevision` 是上次成功保存版本，`dirty` 表示尚未保存。响应 `ETag` 为带引号的版本号。`requiresProxyRestart` 目前为 false：成功应用的修改即时生效，监听改变立即重启。退出接口只返回 `requestId` 与 `data.stopping`。

所有修改配置或保存的接口要求 `If-Match: "3"`。缺少该头返回 428，版本不一致返回 409。版本检查和修改串行执行，两个 UI 页面同时保存不会静默覆盖。UI 遇到冲突应重新读取并让用户重新确认修改内容，不要自动用旧数据覆盖新版本。开始/停止转发、断开会话和诊断任务无需版本号。

错误响应为：

```json
{"requestId":"请求标识","error":{"code":"REVISION_CONFLICT","message":"配置已变化，请重新读取后再提交","field":""}}
```

UI 通过 `error.code` 判断行为，通过中文 `message` 展示原因，不依赖文案匹配。常见状态：400 参数错误、401 令牌错误、403 来源错误、404 不存在、409 冲突、413 请求超过 1 MiB、428 缺少配置版本、429 并发数量达到上限、500 操作失败、503 内核停止或监听恢复失败。

## 接口清单

表内路径均省略 `/api/v1`；标记“版本”的接口要求 `If-Match`。

| 方法与路径 | 输入及用途 | 版本 |
| --- | --- | --- |
| `GET /info` | 内核版本、API 版本、能力列表 | — |
| `GET /health` | 管理接口就绪；不代表代理服务端或目标网站可达 | — |
| `GET /status` | 转发状态、本地监听、默认连接、连接状态、活跃/等待隧道数量、隧道明细、最近错误 | — |
| `GET /tunnels` | 当前全部业务隧道明细，包含代理、直连和等待请求；停止时返回空数组 | — |
| `POST /proxy/start` | 启动转发；至少需一份连接配置；重复启动不产生新实例 | — |
| `POST /proxy/stop` | 关闭所有本地连接和代理会话，保留配置及管理接口 | — |
| `POST /proxy/restart` | 断开所有旧连接并重新启动转发 | — |
| `POST /kernel/shutdown` | 退出内核进程 | — |
| `GET /config` | 完整配置快照，移除密码 | — |
| `POST /config/validate` | 提交完整配置，校验但不应用、不联网测试 | — |
| `PUT /config` | 提交完整配置并立即应用 | 是 |
| `POST /config/save` | 原子保存当前配置到启动时指定的文件，包含密码 | 是 |
| `GET /settings` | 公共配置 `local` | — |
| `PATCH /settings` | 提交需修改的公共字段 | 是 |
| `GET /profiles` | 连接配置列表 | — |
| `POST /profiles` | 新建连接；未指定 id 时生成 UUID；首份自动作为默认连接，返回 201 | 是 |
| `GET /profiles/{id}` | 单份连接配置 | — |
| `PATCH /profiles/{id}` | 修改名称或 config 字段，id 不可修改 | 是 |
| `DELETE /profiles/{id}` | 删除连接；默认连接需先切换，停止状态可删除最后一份 | 是 |
| `POST /profiles/{id}/disconnect` | 关闭该连接的当前会话及其隧道；后续请求按需重新连接 | — |
| `POST /profiles/{id}/tests` | `{"target":"host:port"}`，异步验证连接、认证与目标 CONNECT，返回 202 | — |
| `GET /routing` | 默认连接 ID、当前直连规则文本与精确目标路由 `targetRoutes` | — |
| `PUT /routing/default` | `{"profileId":"节点ID"}`，切换默认连接并关闭旧代理会话 | 是 |
| `PUT /routing/direct-rules` | `{"rules":"example.com\n10.0.0.0/8"}`，替换内联直连规则 | 是 |
| `PUT /routing/targets` | `{"target":"example.com:443","route":"proxy"}`，设置该域名或 IP 的所有端口；route 为 proxy/direct/auto | 是 |
| `POST /routing/validate` | 同上，校验规则但不应用 | — |
| `POST /routing/reload` | 重新读取当前规则来源；存在 routesInline 时仍优先使用内联规则 | 是 |
| `POST /routing/resolve` | `{"target":"host:port"}`，异步解释路由结果，返回 202 | — |
| `GET /operations/{id}` | 查询诊断任务 | — |
| `DELETE /operations/{id}` | 取消诊断任务并释放临时会话 | — |
| `GET /logs?after=0&limit=100&levels=WARN,ERROR` | 按级别增量读取脱敏日志，limit 为 1～500 | — |
| `GET /events` | SSE 状态、配置、日志、诊断任务事件 | — |

`PATCH` 使用递归合并，字段为 null 表示移除。密码省略时保留原密码；空密码会校验失败。查询连接时返回 `hasPassword`，不返回密码。完整配置格式见 [kernel.json 示例](../examples/kernel.json)；配置路径均相对于 `--config` 文件目录，查询和保存时路径会规范化为绝对路径。

新增连接请求示例：

```json
{
  "id": "home-h2",
  "name": "家用 HTTP/2",
  "config": {
    "protocol": "http2",
    "server.host": "proxy.example.com",
    "server.port": 4433,
    "username": "alice",
    "password": "替换为实际密码",
    "tls.serverName": "proxy.example.com"
  }
}
```

`protocol` 支持 `http2`、`http3`。协议、规范化服务器地址和端口共同确定唯一性；重复返回 `PROFILE_DUPLICATE`。同一地址的 HTTP/2 和 HTTP/3 可以各保存一份。最多 128 份配置，当前只使用默认连接；暂未实现不同域名分别走不同代理连接。

## 热更新边界

| 修改 | 生效行为 |
| --- | --- |
| 新增连接、修改非当前连接、修改名称 | 即时更新，不断开当前代理会话 |
| 切换默认连接 | 立即关闭旧代理会话、旧代理隧道及排队请求；直连隧道保持；新请求走新连接 |
| 修改当前连接地址、协议、账号、密码、证书路径、连接参数 | 重建当前代理会话，关闭旧代理隧道；新请求按需连接 |
| 更新直连规则 | 新请求使用新规则；已有及正在建立的业务连接重新判断路由，只关闭直连/代理结果发生变化的连接，共享 HTTP/2、HTTP/3 主连接保持 |
| 设置精确目标路由 | 优先于域名后缀及 IP/CIDR 直连规则；按规范化后的域名或 IP 精确匹配全部端口，不扩展到子域名；只断开路由发生变化的连接 |
| 修改公共 connectTimeoutMillis | 后续新接入的浏览器连接使用新值 |
| 修改本地代理 bind/port | 立即重启转发并断开全部原有连接，包括直连；UI 需同步系统/浏览器代理地址 |
| 新监听启动失败 | 尝试恢复旧监听；返回 409，配置及 revision 不变；已断开的隧道无法恢复 |
| 新旧监听均启动失败 | 返回 503，代理停止；原配置仍保留，管理接口可继续检查和启动 |
| 管理地址、令牌或 CORS 白名单 | 需重启内核进程，通过启动参数修改 |

不会自动监视磁盘文件。通过 API 修改立即应用；修改 `routesFile` 内容后调用规则重载。需要从内联切回文件规则时，PATCH `/settings` 提交 `{"routesInline":null,"routesFile":"pac.txt"}`。替换同一路径的 CA 文件后需显式断开对应会话使证书重新加载。配置保存与应用分离：成功应用后需显式 `/config/save` 才会持久化。

规则变化按最终路由结果判断：移除某条域名规则但仍被另一条规则覆盖时保持连接；仅编辑注释、顺序或重复项不会中断。判断所需的地址已知时，在应用操作中立即发起关闭；已有代理域名因新增网段规则需要 DNS 时，异步解析完成后再决定，API 成功响应不表示这些解析均已结束。连续更新时按最新规则处理 DNS 结果。受影响连接不重放数据，需要浏览器或应用重新请求。

UI 可提示“应用后立即断开路由变化的连接，其余连接保持；网段判断可能需要 DNS 解析”，替换原来的“应用后仅影响新请求”。此行为同时适用于内联规则更新、文件重载和修改规则来源，无需增加接口或重启代理服务端。主动断开会输出 INFO 日志，包含目标和新旧路由，可通过现有日志接口查询。

业务连接以浏览器提交的 HTTP/CONNECT 目标为判断单位，内核不解析 TLS 隧道内的加密请求。

## 隧道列表

`GET /tunnels` 的 `data` 是当前全部业务隧道的数组；`/info` 通过 `tunnels` 能力标记提供此功能。`GET /status` 与 SSE 的 `snapshot`、`status` 中也包含同一格式的 `tunnels` 数组，明细变化会触发状态推送。内核每 250 毫秒检查状态变化；短于该间隔的请求可能不会出现在事件快照中，此接口不用于请求审计。

每项包含 `id`（本地连接 ID）、`target`（HTTP/CONNECT 目标）、`source`（本地请求来源）、`route`（resolving/proxy/direct）、`state`（resolving/pending/active）、`profileId`、`profileName`、`protocol`（http2/http3/tcp）以及 `createdAt`（收到请求时的 Unix 毫秒时间）。IPv6 地址使用方括号。DNS 路由解析期间为 resolving，等待 TCP 或代理流建立时为 pending，远端连接建立后为 active；直连的连接配置 ID 和名称为空，协议为 tcp。

列表包括普通 HTTP 转发、CONNECT 隧道和直连 TCP 连接，不包括尚未收到请求的本地空闲套接字、共享 HTTP/2 或 QUIC 主连接、独立诊断会话。连接关闭后自动移除，不保存历史记录。读取不改变配置版本、路由或代理连接；返回信息不包含密码、请求正文或 TLS 隧道内的数据。

隧道列表可通过 `PUT /routing/targets` 切换目标路由；`targetRoutes` 能力表示内核支持此操作。`proxy` 强制走当前默认代理连接，`direct` 强制直连，`auto` 删除该目标的覆盖并恢复原直连规则判断。目标规范化忽略域名大小写和尾部句点，IPv6 不同写法视为同一地址。操作不会迁移或重放已有连接，路由变化时关闭原连接，由浏览器或应用重连；切换同一路由时保留连接，重复设置不推进配置版本。

精确规则存储在 `local.routesOverrides` 字符串，每行格式为 `proxy 域名或IP` 或 `direct 域名或IP`，不包含端口；此字段与 `routesInline` / `routesFile` 独立，保持原规则文本和来源。`GET /routing` 的 `targetRoutes` 返回主机到 proxy/direct 的对象。成功应用后仍需通过 `POST /config/save` 持久化；完整配置 PUT 需带回此字段以保留目标规则。

## 异步诊断与事件

测试返回的 `data` 包含 `id`、`state`、`stage`、`createdAt`、`elapsedMillis`、`stages`、`result`。状态为 queued/running/succeeded/failed/cancelled。最多同时运行 4 项任务，保留最近 128 项；取消不影响实际代理会话。任务结束后通过查询或 SSE 读取结果。

连接诊断阶段可能包括 configuration、dns、tcp、tls、http2_settings、quic_tls、connect。阶段按观察到的状态变化记录，快速阶段可能省略，时间为从任务开始累计的毫秒数。诊断成功仅说明指定目标 TCP 隧道和代理认证成功，不代表目标网站 TLS 或 HTTP 请求成功。失败结果提供阶段和错误码，例如 TCP_CONNECT_FAILED、TLS_TIMEOUT、AUTHENTICATION_FAILED。目标由代理服务端连接，不会借用现有代理会话。

代理运行时，规则查询和路由解释使用实际生效的规则快照。外部修改规则文件不会立即生效，可调用规则重载接口应用；其他重新应用配置的操作也会加载规则文件。代理停止时读取配置指定的规则。

路由解释返回 direct/proxy/unavailable，以及 target_rule/direct_rule/ip_rule/default 命中类别。含 IP/CIDR 规则时可能进行 DNS 查询；解析失败时与实际路由行为一致，使用默认代理。

SSE 初次订阅发送 `snapshot`，之后发送 `status`、`configuration`、`log`、`operation`。每条包含 id/event/data。重新订阅可通过 `Last-Event-ID` 请求补发，最近保留 512 条，游标过期时发送新快照，UI 应重新读取配置、日志或任务。最多 16 个 SSE 订阅。每 10 秒的注释帧只维持管理事件流，不是代理内核与代理服务端之间的业务心跳。

日志接口支持 `levels` 参数，多个级别用逗号分隔，不区分大小写；省略时返回全部已采集级别。按精确级别匹配，不是严重程度阈值：`levels=WARN` 只返回警告，`levels=ERROR,FATAL` 返回错误及致命错误。无效级别或空值返回 400 / INVALID_LOG_LEVEL。

```text
GET /api/v1/logs?levels=WARN&after=0&limit=100
GET /api/v1/logs?levels=ERROR,FATAL&after=0&limit=100
GET /api/v1/logs?levels=INFO,WARN,ERROR&after=0&limit=100
```

支持 FATAL、ERROR、WARN、INFO、DEBUG、TRACE，但只返回实际被日志配置采集的记录；默认 INFO 级别下没有 DEBUG/TRACE 记录，查询不会改变日志采集级别。SSE 日志事件仍包含全部已采集级别，UI 按事件的 `level` 字段筛选。

日志最多保留 500 条，每条最长 4096 字符。`cursor` 是本页最后一条匹配记录的序号，无匹配时推进至当前最新序号；下一页传 `after=cursor` 并保留筛选条件。切换筛选条件时重置 `after=0`，以重新读取保留的历史记录；`latestCursor` 为最新记录序号，`truncated` 表示旧记录已淘汰。已知代理密码会被替换为 `***`，但目标域名等运行信息仍可能出现，分享日志前请检查内容。

## Flutter 接入顺序

1. 使用 `--web --port 0 --config <配置路径> --endpoint-file <应用数据目录/control.json>` 启动 Java 进程，不通过 stdin 发送命令。
2. 读取发现文件的管理地址和令牌，获取 `/info`、`/status`、`/config`，保存 revision。
3. 建立带 Authorization 的 SSE 流，展示连接状态和日志。
4. 首次使用时创建连接，配置本地监听，调用 `/proxy/start`；服务端连接按实际代理请求建立。
5. 每次配置修改带最新 If-Match，按响应刷新 UI；需要保留时调用 `/config/save`。
6. 关闭窗口只断开 UI 订阅。用户选择“停止代理”时调用 `/proxy/stop`；选择“退出内核”时才调用 `/kernel/shutdown`。

## 本机验证

```sh
mvn -B -ntp test
mvn -B -ntp package
python3 scripts/web-smoke-test.py
```

测试覆盖真实 HTTP 管理请求、认证/CORS、版本冲突、配置脱敏/保存、规则热更新、当前连接变更、监听立即重启及失败回退、异步任务取消和 UI 断开后继续运行。测试使用本机 HTTP/2、HTTP/3 服务及测试证书，不访问公网。
