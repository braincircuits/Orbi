# 代理内核 Web 管理接口 v1

Flutter UI（代理客户端）使用此接口管理 Java 代理内核；接口不在代理服务端提供。代理内核本地代理端口负责浏览器流量，管理端口负责配置和状态。

## 启动与生命周期

代理内核只有 Web 管理入口。必须使用 `--web` 启动，不支持无参数启动、直接传入配置文件路径或旧管道模式。发布脚本也遵循这一行为。

```sh
java --enable-native-access=ALL-UNNAMED -jar ClientG/target/clientG-1.0-SNAPSHOT.jar \
  --web --db /数据目录/kernel.db --port 9090
```

发布目录中将 JAR 路径换成 `client.jar`。省略 `--db` 时使用 JAR 或原生可执行程序同目录的 `kernel.db`，不依赖工作目录；IDE 类路径运行时使用编译输出目录。

| 参数 | 含义 |
| --- | --- |
| `--db` | SQLite 数据库路径；不存在时自动建库，以空连接和空规则启动；默认位于程序目录 |
| `--storage-config` | UTF-8 存储配置文件，选择 SQLite/PostgreSQL/MySQL，重启生效；与 `--db` 互斥，见 [数据库切换](database-storage.md) |
| `--port` | 本机管理端口，默认 9090；0 表示自动分配 |
| `--endpoint-file` | 管理连接信息文件，SQLite 默认在数据库目录下，远程库默认在存储配置目录下的 `run/control.json` |
| `--token-file` | 可选，从文件读取至少 32 个非空白可打印 ASCII 字符的管理令牌；默认每次启动生成随机令牌 |
| `--allow-origin` | 可重复指定网页 Origin，例如 `http://localhost:3000`；默认不允许其他网页来源 |

管理接口固定监听 `127.0.0.1`。发现文件包含 `url`、`token`、`pid`、`apiVersion`，在支持 POSIX 权限的平台设置为 `600`，正常退出时清理。请将自定义发现文件加入 Git 忽略规则。令牌不写入日志，也不通过查询接口返回。持有令牌的同机程序能修改代理配置，应妥善保管发现文件。

Web 模式启动后不会自动开启代理转发。UI 先读取配置，再调用 `/proxy/start`。UI 关闭、HTTP 请求断开、SSE 订阅断开、标准输入关闭均不停止内核；退出必须显式调用 `/kernel/shutdown` 或由进程管理器终止。`/proxy/stop` 只停止转发，管理接口仍可使用。配置修改成功即持久化，进程重启后恢复。

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
  "requiresProxyRestart": false,
  "requestId": "请求标识",
  "data": {}
}
```

`revision` 是数据库中持久化的配置版本，重启不归零。没有手动保存和未保存状态。响应 `ETag` 为带引号的版本号。`requiresProxyRestart` 目前为 false：成功应用的修改即时生效，监听改变立即重启。退出接口只返回 `requestId` 与 `data.stopping`。

所有修改配置的接口要求 `If-Match: "3"`。缺少该头返回 428，版本不一致返回 409。版本检查和修改串行执行，两个 UI 页面同时修改不会静默覆盖。UI 遇到冲突应重新读取并让用户重新确认修改内容，不要自动用旧数据覆盖新版本。开始/停止转发、断开会话和诊断任务无需版本号。

错误响应为：

```json
{"requestId":"请求标识","error":{"code":"REVISION_CONFLICT","message":"配置已变化，请重新读取后再提交","field":""}}
```

UI 通过 `error.code` 判断行为，通过中文 `message` 展示原因，不依赖文案匹配。常见状态：400 参数错误、401 令牌错误、403 来源错误、404 不存在、409 冲突、413 请求超过 1 MiB、428 缺少配置版本、429 并发数量达到上限、500 操作失败、503 数据库写入失败、内核停止或运行配置恢复失败。

## 接口清单

表内路径均省略 `/api/v1`；标记“版本”的接口要求 `If-Match`。

| 方法与路径 | 输入及用途 | 版本 |
| --- | --- | --- |
| `GET /info` | 内核版本、API 版本、能力列表 | — |
| `GET /health` | 管理接口就绪；不代表代理服务端或目标网站可达 | — |
| `GET /status` | 转发状态、本地监听、默认连接、连接状态、活跃/等待隧道数量、隧道明细、最近错误 | — |
| `GET /tunnels` | 当前全部业务隧道明细，包含代理、直连和等待请求；停止时返回空数组 | — |
| `POST /proxy/start` | 启动转发；直连模式无需服务端配置，其他模式至少需一份连接配置；重复启动不产生新实例 | — |
| `POST /proxy/stop` | 关闭所有本地连接和代理会话，保留配置及管理接口 | — |
| `POST /proxy/restart` | 断开所有旧连接并重新启动转发 | — |
| `POST /kernel/shutdown` | 退出内核进程 | — |
| `GET /config` | 完整配置快照，移除密码 | — |
| `POST /config/validate` | 提交完整配置，校验但不应用、不联网测试 | — |
| `PUT /config` | 提交完整配置并立即应用 | 是 |
| `GET /settings` | 公共配置 `local` | — |
| `PATCH /settings` | 提交需修改的公共字段 | 是 |
| `GET /profiles` | 连接配置列表 | — |
| `POST /profiles` | 新建连接；未指定 id 时生成 UUID；首份自动作为默认连接，返回 201 | 是 |
| `GET /profiles/{id}` | 单份连接配置 | — |
| `PATCH /profiles/{id}` | 修改名称或 config 字段，id 不可修改 | 是 |
| `DELETE /profiles/{id}` | 删除连接；默认连接需先切换，停止状态可删除最后一份 | 是 |
| `POST /profiles/{id}/disconnect` | 关闭该连接的当前会话及其隧道；后续请求按需重新连接 | — |
| `POST /profiles/{id}/tests` | `{"target":"host:port"}`，异步验证连接、认证与目标 CONNECT，返回 202 | — |
| `GET /routing/export` | 导出路由文档，响应 data 可直接保存为 UTF-8 JSON | — |
| `POST /routing/preview` | 校验并预览规则合并或替换结果，不保存 | 是 |
| `POST /routing/import` | 按 merge/replace 导入规则并自动保存；详见下文 | 是 |
| `POST /profiles/export` | 指定连接 IDs 及是否包含密码，导出连接文档 | — |
| `GET /routing` | 默认连接 ID、当前直连规则文本与精确目标路由 `targetRoutes` | — |
| `PUT /routing/mode` | `{"mode":"rules"}`，模式为 rules/direct/proxy，即时生效并持久化 | 是 |
| `POST /overview/latency` | 当前代理连接 RTT，HTTP/2 PING 或 QUIC 路径 RTT，返回 202 | — |
| `POST /overview/websites` | 按当前路由依次测试 GitHub、Google、YouTube 的 HTTPS 响应耗时，返回 202 | — |
| `POST /overview/exit-ip` | 从当前路由查询出口公网 IP、归属地和运营商，返回 202 | — |
| `GET /traffic` | 当前或最近一次代理启动的累计量、速率及最近一小时历史 | — |
| `GET /traffic/trend` | 最近24小时的分钟区间流量 | — |
| `GET /traffic/history` | 最近一个自然月的已完成小时流量 | — |
| `GET /access-records` | 分页查询长期保存的访问目标和连接结果 | — |
| `PUT /routing/default` | `{"profileId":"节点ID"}`，切换默认连接并关闭旧代理会话 | 是 |
| `PUT /routing/direct-rules` | `{"rules":"example.com\n10.0.0.0/8"}`，替换内联直连规则 | 是 |
| `PUT /routing/targets` | `{"target":"example.com:443","route":"proxy"}`，设置该域名或 IP 的所有端口；route 为 proxy/direct/auto | 是 |
| `POST /routing/validate` | 同上，校验规则但不应用 | — |
| `POST /routing/resolve` | `{"target":"host:port"}`，异步解释路由结果，返回 202 | — |
| `GET /operations/{id}` | 查询诊断任务 | — |
| `DELETE /operations/{id}` | 取消诊断任务并释放临时会话 | — |
| `GET /logs?after=0&limit=100&levels=WARN,ERROR` | 按级别增量读取脱敏日志，limit 为 1～500 | — |
| `GET /events` | SSE 状态、配置、日志、诊断任务事件 | — |

`PATCH` 使用递归合并，字段为 null 表示移除。密码省略时保留原密码；空密码会校验失败。查询连接时返回 `hasPassword`，不返回密码。完整配置请求体见 [API 请求示例](../examples/config-request.json)，该示例不是启动配置文件。证书相对路径在 SQLite 模式下以数据库所在目录为基准，远程数据库模式下以启动存储配置文件所在目录为基准，查询返回绝对路径。

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

配置和规则只存储在启动时选定的数据库中，通过 API 修改即时应用并自动保存。`routesFile`、规则文件重载与手动保存接口已删除。替换同一路径的 CA 文件后需显式断开对应会话使证书重新加载。数据库事务失败会撤销修改并恢复运行配置；若恢复失败则停止代理并返回明确错误，已断开的连接无法恢复。

规则变化按最终路由结果判断：移除某条域名规则但仍被另一条规则覆盖时保持连接；仅编辑注释、顺序或重复项不会中断。判断所需的地址已知时，在应用操作中立即发起关闭；已有代理域名因新增网段规则需要 DNS 时，异步解析完成后再决定，API 成功响应不表示这些解析均已结束。连续更新时按最新规则处理 DNS 结果。受影响连接不重放数据，需要浏览器或应用重新请求。

UI 可提示“应用后立即断开路由变化的连接，其余连接保持；网段判断可能需要 DNS 解析”，替换原来的“应用后仅影响新请求”。此行为同时适用于规则更新和路由导入，无需重启代理服务端。主动断开会输出 INFO 日志，包含目标和新旧路由，可通过现有日志接口查询。

业务连接以浏览器提交的 HTTP/CONNECT 目标为判断单位，内核不解析 TLS 隧道内的加密请求。

## 隧道列表

`GET /tunnels` 的 `data` 是当前全部业务隧道的数组；`/info` 通过 `tunnels` 能力标记提供此功能。`GET /status` 与 SSE 的 `snapshot`、`status` 中也包含同一格式的 `tunnels` 数组，明细变化会触发状态推送。内核每 250 毫秒检查状态变化；短于该间隔的请求可能不会出现在事件快照中，此接口不用于请求审计。

TUN 的 TCP/UDP 53 端口 DNS 查询也遵循全局模式与查询域名规则：直连使用客户端系统 DNS，代理通过当前默认连接使用服务端系统 DNS。精确域名覆盖优先于后缀直连规则；查询前不通过本机解析来匹配结果 IP 的网段规则。应用配置会清空 DNS 响应缓存并取消在途查询，未过期的 IP→域名关联保留。客户端与服务端均需支持 DNS 隧道标识，失败不自动直连；现有管理请求格式不变。

每项包含 `id`（本地连接 ID）、`target`（HTTP/CONNECT 目标；TUN 连接存在有效 DNS 关联时显示关联域名和原端口）、`source`（本地请求来源）、`route`（resolving/proxy/direct）、`state`（resolving/pending/active）、`profileId`、`profileName`、`originalProtocol`（原始传输协议 tcp/udp）、`protocol`（实际连接协议 http2/http3/tcp/udp）以及 `createdAt`（收到请求时的 Unix 毫秒时间）。IPv6 地址使用方括号。DNS 路由解析期间为 resolving，等待目标套接字或代理流建立时为 pending，建立后为 active；直连的连接配置 ID 和名称为空，协议按目标传输类型为 tcp 或 udp。UDP 关联的 active 不代表目标在线。`originalProtocol` 在代理、直连及路由待确定期间均保留原始 TCP/UDP 类型，不随外层代理协议变化。域名访问统计不再保存逐连接协议，协议详情仅在实时隧道中展示。

列表包括普通 HTTP 转发、CONNECT 隧道和直连 TCP 连接，不包括尚未收到请求的本地空闲套接字、共享 HTTP/2 或 QUIC 主连接、独立诊断会话。连接关闭后自动移除，不保存历史记录。读取不改变配置版本、路由或代理连接；返回信息不包含密码、请求正文或 TLS 隧道内的数据。

隧道列表可通过 `PUT /routing/targets` 切换目标路由；`targetRoutes` 能力表示内核支持此操作。`proxy` 强制走当前默认代理连接，`direct` 强制直连，`auto` 删除该目标的覆盖并恢复原直连规则判断。目标规范化忽略域名大小写和尾部句点，IPv6 不同写法视为同一地址。操作不会迁移或重放已有连接，路由变化时关闭原连接，由浏览器或应用重连；切换同一路由时保留连接，重复设置不推进配置版本。

精确规则存储在 `local.routesOverrides` 字符串，每行格式为 `proxy 域名或IP` 或 `direct 域名或IP`，不包含端口；此字段与 `routesInline` 独立，保持原直连规则文本。数据库按目标逐行存储精确规则。`GET /routing` 的 `targetRoutes` 返回主机到 proxy/direct 的对象。成功应用后自动持久化；完整配置 PUT 需带回此字段以保留目标规则。

## 异步诊断与事件

测试返回的 `data` 包含 `id`、`state`、`stage`、`createdAt`、`elapsedMillis`、`stages`、`result`。状态为 queued/running/succeeded/failed/cancelled。最多同时运行 4 项任务，保留最近 128 项；取消不影响实际代理会话。任务结束后通过查询或 SSE 读取结果。

连接诊断阶段可能包括 configuration、dns、tcp、tls、http2_settings、quic_tls、connect。阶段按观察到的状态变化记录，快速阶段可能省略，时间为从任务开始累计的毫秒数。诊断成功仅说明指定目标 TCP 隧道和代理认证成功，不代表目标网站 TLS 或 HTTP 请求成功。失败结果提供阶段和错误码，例如 TCP_CONNECT_FAILED、TLS_TIMEOUT、AUTHENTICATION_FAILED。目标由代理服务端连接，不会借用现有代理会话。

规则查询和路由解释始终使用当前配置快照，外部 PAC 文件不参与路由。不要直接修改运行中的数据库。

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

1. 使用 `--web --port 0 --db <数据库路径> --endpoint-file <应用数据目录/control.json>` 启动 Java 进程，不通过 stdin 发送命令。
2. 读取发现文件的管理地址和令牌，获取 `/info`、`/status`、`/config`，保存 revision。
3. 建立带 Authorization 的 SSE 流，展示连接状态和日志。
4. 首次使用时创建连接，配置本地监听，调用 `/proxy/start`；服务端连接按实际代理请求建立。
5. 每次配置修改带最新 If-Match，按响应刷新 UI；成功即已保存。
6. 关闭窗口只断开 UI 订阅。用户选择“停止代理”时调用 `/proxy/stop`；选择“退出内核”时才调用 `/kernel/shutdown`。

## 本机验证

```sh
mvn -B -ntp test
mvn -B -ntp package
python3 scripts/web-smoke-test.py
```

测试覆盖真实 HTTP 管理请求、认证/CORS、版本冲突、配置脱敏/保存、规则热更新、当前连接变更、监听立即重启及失败回退、异步任务取消和 UI 断开后继续运行。测试使用本机 HTTP/2、HTTP/3 服务及测试证书，不访问公网。

## 概览与全局模式

`local.routingMode` 可取 `rules`（默认按规则）、`direct`（全部直连）、`proxy`（全部代理）。后两者覆盖精确目标和直连规则，但不改写规则内容；切回 rules 后规则重新参与路由。模式只作用于进入本地 HTTP 代理的流量，不修改操作系统代理或接管未接入应用的流量。模式变化关闭路由发生变化的业务连接，转入直连还会关闭代理主连接。`GET /routing` 返回 `mode`，状态及 SSE 快照返回 `routingMode`。

概览检测复用 `/operations/{id}` 和 SSE `operation` 事件，不阻塞管理接口。停止状态返回 `409 PROXY_STOPPED`；直连模式的服务端 RTT 检测返回 `409 DIRECT_MODE`。HTTP/2 RTT 不包含首次握手时间，QUIC 返回当前路径平滑 RTT，均为毫秒；不能把网站响应耗时当作服务端 RTT。

任务 `context` 包含 `kind`（latency/websites/exit-ip）、`generation`、`mode` 和 `profileId`。状态中的 `networkGeneration` 在配置应用、会话断开、启停时递增，并取消旧概览任务。UI 应同时核对内核实例和 generation，仅展示当前上下文的结果；取消或迟到事件不可恢复旧值。

- latency 成功结果：`{"latencyMillis":12.4,"checkedAt":"ISO-8601 时间"}`。
- websites 逐站推送 `result.websites`，每项包含 `id`、`url`、`state`、`checkedAt`；收到 HTTP 响应时还包含 `httpStatus` 和 `latencyMillis`。state 为 reachable（2xx/3xx）、http_error（其他响应码）、timeout 或 failed；部分失败不终止其他网站测试。取消保留已完成的结果。
- 网站使用 HTTPS HEAD 请求，延迟从请求发起到响应头完成，包含本地入口、DNS、握手和响应等待；每站最多 5 秒，不跟随重定向。全局代理不允许失败后回退直连。
- exit-ip 成功结果包含 `ip`、`country`、`region`、`city`、`provider`、`source`、`checkedAt`。缺失的归属字段为空字符串，UI 显示未知；不编造定位。使用 [ipwho.is 官方接口](https://ipwhois.io/documentation)，只在用户查询时访问，响应最大 64 KiB，5 秒超时。查询的是该服务实际看到的出口，规则分流时不同目标的出口可能不同。请求不携带管理令牌或代理凭据；外部服务不可用时明确失败。

## SQLite 与路由导入导出

内核也支持 PostgreSQL 和 MySQL 整体存储，选型、启动参数及事务边界见 [数据库切换](database-storage.md)。`GET /info` 增加 `storageBackend` 字段返回实际后端，能力列表包含 `sqlite`、`postgresql`、`mysql`，不包含数据库凭据。下面关于文件权限和锁文件的说明仅适用于 SQLite。

内核使用选定数据库保存本地设置、连接及凭据、路由和 revision。数据库文件及锁文件限制当前用户访问；数据库未加密，不应分发给无权获得代理凭据的用户。日志、SSE、诊断和活动隧道不保存到数据库。`run/control.json` 是当前进程的管理发现文件，继续独立生成和清理。

同一数据库只允许一个内核实例持有；重复启动会报错。数据库损坏、格式或结构版本不支持时拒绝启动，不自动重建、迁移或回退读取旧 JSON/PAC 文件，也不删除旧文件。数据库目录必须可写，以便创建事务日志与锁。锁文件和已截断的 `kernel.db-journal` 退出后保留，但操作系统锁会释放。备份或复制数据库前先停止内核。

### 路由规则文件

`GET /routing/export` 返回的 `data` 可直接保存为 UTF-8 JSON，文件只包含直连规则、备注和指定目标规则，不包含运行模式、默认连接或凭据。当前交换格式如下，不兼容旧版本路由文件：

```json
{
  "version": 2,
  "kind": "network-routes",
  "directRules": "# 内网直连\n10.0.0.0/8\nexample.com\n",
  "targetRoutes": {"www.example.com": "proxy", "127.0.0.1": "direct"}
}
```

`POST /routing/preview` 和 `POST /routing/import` 请求体为 `{"document": <文件对象>, "strategy": "merge"}`，均携带当前 `If-Match`。`strategy` 只允许 `merge`、`replace`。预览返回候选文件，配置和版本不变；实际导入重新校验版本并原子保存，校验失败或版本冲突不写入。

- 合并：保留现有直连规则和备注，重复域名/IP/CIDR去重；同一指定目标的走向以导入文件为准。
- 整体替换：完整替换直连规则和指定目标规则，空值可以清空对应规则。
- 两种方式均保留当前运行模式、默认连接及其他配置。规则更新沿用既有热更新行为。
- UI 导入前要求处理已有草稿，显示候选规则后再确认。原有直连文本导入仍单独进入草稿。

### 连接配置文件

`POST /profiles/export` 请求体为 `{"ids":["节点ID"],"includePassword":false}`，必须明确指定至少一个已保存连接。只有 `includePassword=true` 时输出密码；普通配置查询和 SSE 均不返回密码。

```json
{
  "version": 1,
  "kind": "network-connections",
  "connections": [
    {"name": "示例连接", "config": {"protocol": "http2", "server.host": "proxy.example", "server.port": "443", "username": "demo"}}
  ]
}
```

文件不包含连接 ID、默认连接、本机 Java/JAR 路径、数据库设置或运行状态。`config` 使用现有连接参数；证书路径作为连接参数保留，但证书内容不打包，导入后需核对本机文件。UI 支持选择单个、多个或全部连接导出，密码选项默认关闭，勾选时提示明文风险。macOS 文件导出使用私有临时文件原子替换，并保留仅当前用户读写的权限。

连接导入校验文件后进入编辑草稿，复用现有 `PUT /config` 应用并保存，不增加第二套写入接口。同名连接可明确选择覆盖某个现有连接，或者作为新连接并自动区分名称；新连接使用新 ID。无密码的新连接需要补填；无密码的覆盖保留被覆盖连接自己的密码。默认连接保持不变，空配置首次导入以第一项作为默认连接。最终应用仍检查地址、参数、证书和重复服务端配置。

两种文件均限制 1 MiB，拒绝未知字段及未知版本。旧文件不自动迁移或回退读取。

## 流量统计

`GET /traffic` 返回 `sessionId`、`startedAt`、`sampledAt`、`sentBytes`、`receivedBytes`、`sendBytesPerSecond`、`receiveBytesPerSecond`。时间为 Unix 毫秒，累计值为字节，速率为字节／秒。每秒采样，只保留最新速率；状态响应与 SSE 快照结构一致，不再传输秒级历史窗口。

统计涵盖接入内核的代理与直连业务流量，不包含本地 CONNECT 握手、代理认证、协议帧、TLS／QUIC 封装与重传。发送统计成功写入业务流的字节，接收统计业务流读入字节。停止代理归零速率并保留本次累计值；再次启动创建新会话。切换路由、默认连接、TUN 出口或重建监听保持同一运行会话。

### 分钟趋势与小时历史

- `GET /traffic/trend`：返回最近24小时的分钟区间，包括当前分钟的位置。正常停止时保存的不足一分钟记录可见，仍未结束的区间在标签中标注；运行中尚未保存的字节不计入图表。
- `GET /traffic/history`：仅返回最近一个自然月内已经完成的小时，从当前整点按自然月回推。数据库实际保留最近12个月的小时数据，界面不提供更早月份入口。

两个接口的范围均由内核时区计算，不接收客户端日历边界或分页游标。响应 `data` 包含 `from`、`to`（左闭右开 Unix 毫秒）、`zoneId`、`interval`（`minute`／`hour`）、`sentBytes`、`receivedBytes`、`recordCount` 和 `buckets`。

每个桶包含 `from`、`to`、`sentBytes`、`receivedBytes`、`recordCount`、`label`、`shortLabel`。标签由内核按自身时区格式化，详细标签含 UTC 偏移，以区分夏令时回拨时的重复小时。桶有记录时 `recordCount=1`，缺失时为0；整个范围的计数为有效桶数。纵轴为区间流量，缺失区间断开，运行但无流量的区间显示0。分钟趋势提供1小时、6小时、24小时查看范围；小时历史固定最近1个月。

实际字节按发生时间归入自然分钟，每分钟结束或正常停止时入队落库，不定时保存未结束分钟。同一分钟跨启动会话合并到唯一记录；保存各会话最终快照，使重复批次幂等。整点将上一小时尚未汇总的增量写入小时表，小时值与分钟汇总检查点在同一事务提交；延迟写入可补算，重复维护不重复累计。

每分钟维护清理超过24小时、且已成功汇总的分钟数据。每次内核启动及内核时区凌晨03:00清理12个自然月之前的小时数据；先补算，再清理。停机错过计划则启动时补做。数据库失败时保留待写入批次，汇总失败不删除对应分钟数据。异常退出可能丢失当前尚未结束的分钟及存储失败时的队列数据。

旧历史由用户手动处理，不读取、迁移或删除旧格式记录。现有 `traffic_minutes` 表结构不匹配时明确拒绝启动；不要将本次结构调整视作旧数据迁移。

## 域名访问统计

`GET /access-records` 读取已经保存的域名累计统计，不触发提前落库。查询参数：`target`（域名/IP字面子串）、`failedOnly=true|false`（默认 false）、`order=host|count|recent|failure`（域名、连接次数、最后访问、最后失败，默认 recent）、`ascending=true|false`（默认 false）、`limit`（1～500，默认100）、`beforeValue`、`afterHost`。首次请求省略游标，后续请求带回 `nextValue` 和 `nextHost`；按选定列和方向对全部已保存数据排序；数值相同的行固定按域名升序分页。域名排序只使用 `nextHost`，`nextValue` 返回0；无失败记录按数值0参与排序，界面显示“—”。计数持续变化时刷新可读取最新排序；UI 对重复域名去重，切换筛选或排序从首页开始。

响应包含 `items`、`hasMore`、`nextValue`、`nextHost`。每条统计仅包含 `host`、`connectionCount`、`lastAccessAt`、`lastFailureAt`；时间为 Unix 毫秒，没有失败时为0。完整域名分开，大小写、尾点和等价IP写法归一化；不同端口、TCP/UDP、代理/直连和连接节点合并。没有DNS域名关联时按IP保存；有效关联沿用最新域名，过去的统计不追溯改名。

连接发起时计数一次，成功、失败、主动取消均不追加次数；内部连接重试不重复计数。最后访问时间是最近发起时间，最后失败时间只更新建立失败，之后成功不清空。TCP长连接内多个请求不逐个计数，UDP按现有会话统计。统计不表示网页请求次数或HTTP业务成功，不记录端口、来源、URL路径、协议、凭据或正文。

转发线程在内存按域名合并变化，控制线程每个自然分钟批量提交，正常停止代理和退出内核时补写。无变化时不写入；失败批次保留并在一分钟后重试，后续增量与待重试批次分离。批次标记与累计统计在同一事务提交，重试不重复计数。异常退出或长期存储故障可能丢失内存中未保存的增量。

`access_domains` 长期保存累计统计，不参与流量数据过期清理。`access_flush` 只保留最后一个提交批次标记，不随连接数增长。旧 `access_records` 明细表不再创建、读取或写入，已有内容不迁移、不删除，由使用者手动处理。`status.historyStorage` 继续报告待保存数量、丢弃数量及错误。

## macOS TUN 生命周期

`info.capabilities` 包含 `macosTun`；桌面 UI 同时检查 macOS 宿主及打包的辅助程序。`status.tun` 包含 `state`、`error`、`engine`、`interfaceIndex`。状态为 `off`、`authorizing`、`starting`、`running`、`stopping` 或 `failed`。这些运行状态不持久化；以下接口需要 Bearer 认证，无需 `If-Match`。

| POST 路径 | 请求及行为 |
| --- | --- |
| `/tun/request` | 必须提交 `{"engine":"outline"}` 或 `{"engine":"tun2socks"}`，缺失或未知值返回 400；代理运行时创建单次 `ticket`，进入 `authorizing`；重复启动返回 409 |
| `/tun/prepare` | 辅助进程提交 `{"interface":"en0","ticket":"启动标识"}`，验证真实网络接口并重建受保护的 Java 出口；返回 `session`、本机 `proxy` 地址和本次 `engine`，进入 `starting`；此时尚未安装系统路由 |
| `/tun/heartbeat` | 辅助进程提交 `{"session":"会话标识","ready":true}`；仅路由与转发就绪后设置 `ready:true`，进入 `running`；返回 `stop`，为 true 时必须清理并退出 |
| `/tun/stop` | 授权阶段立即撤销 ticket；其他活动阶段标记 `stopping`，由辅助进程清理；返回当前状态 |
| `/tun/finish` | 辅助进程先移除路由并关闭 utun，再提交 `{"session":"会话标识","error":""}`；恢复普通内核出口并进入 `off`，非空错误进入 `failed`；旧会话退出不能覆盖新会话 |

辅助进程每两秒续约；授权超时 120 秒、准备阶段超时 30 秒、运行阶段失联 10 秒会使会话失效。授权超时保留普通代理；准备或运行期间失联会停止 Java 代理，避免在状态不明时继续转发。正常关闭 TUN 仍保持普通代理运行；停止代理或关闭内核也会通知或使辅助进程检测到退出条件。TUN 活动期间禁止修改本地监听地址/端口及直接重启代理，规则、模式与节点操作保持可用。

组件选择在单次会话内固定；切换组件需调用 `/tun/stop`，等待 `off` 及桌面辅助进程退出，再以新 `engine` 请求启动。桌面 UI 在 `ui.json` 保存选择，不修改代理配置或数据库。当前 UI、内核和辅助程序配套更新，不提供旧协议回退。

这些管理接口本身不创建 utun。系统路由仅由获得管理员授权的辅助进程管理；不要绕过「先绑定出口，再安装路由；先清理路由，再恢复出口」的顺序。
