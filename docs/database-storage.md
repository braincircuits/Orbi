# 内核数据库切换

内核支持 SQLite、PostgreSQL 14+、MySQL 8.4+。选中的数据库统一保存本地设置、代理连接和凭据、路由规则、配置版本、流量采样及访问记录。通过启动参数选定，修改后重启；管理 API 的配置格式不变。

## 启动

不指定存储参数时，仍使用程序旁的 `kernel.db`。也可直接指定 SQLite 文件：

```sh
java -jar client.jar --web --db /数据目录/kernel.db
```

使用启动配置文件选择任一后端：

```sh
java -jar client.jar --web --storage-config /数据目录/storage.properties
```

`--db` 和 `--storage-config` 不能同时指定。配置文件为 UTF-8 properties，字段与样例见：

- [SQLite](../examples/storage-sqlite.properties)
- [PostgreSQL](../examples/storage-postgresql.properties)
- [MySQL](../examples/storage-mysql.properties)

远程数据库必须预先创建。内核在 PostgreSQL 的 `public` schema 或 MySQL 选定数据库中创建业务表，需要相应建表、建索引及读写权限。不支持 MariaDB 或数据库代理的事务池模式；独占锁必须与同一条数据库会话绑定。

`passwordEnv` 指定进程环境变量的名称；也可以使用 `password`，两者不能共存。未知字段、无效端口和不匹配的数据库类型会拒绝启动，不会默默忽略。密码、URL 不输出到管理 API。含明文密码的文件应仅由当前用户读取。

`sslMode` 只支持 `verify-full`（默认，验证服务器证书及主机名）和 `disable`（不使用 TLS，限明确配置的可信测试网络）。PostgreSQL 按 pgJDBC 的默认根证书位置验证，MySQL 使用 Java 信任库；自签证书须先配置对应信任来源。连接超时为 5 秒，套接字读取超时为 10 秒。

SQLite 相对证书路径和默认 `run/control.json` 仍基于数据库目录。远程数据库则基于存储配置文件所在目录，发现文件仍保存在本机；可用 `--endpoint-file` 显式指定位置。Flutter 界面提供独立数据库设置，见下文。

启动日志会显示当前后端；`GET /api/v1/info` 的 `storageBackend` 为 `sqlite`、`postgresql` 或 `mysql`，能力列表包含三种后端。该响应不包含数据库地址、用户名和密码。

## 在桌面界面配置

打开“设置 → 数据库 → 配置数据库”。选择 SQLite、PostgreSQL 或 MySQL；SQLite 填写文件路径，远程库填写地址、端口、数据库名、用户名及密码。TLS 默认开启并验证服务器证书；仅在明确使用不加密连接时关闭。

点击“保存并重启内核”后，现有代理连接会断开，界面读取新库中的配置。请检查配置后再启动代理。启用虚拟网卡时须先关闭；有未保存的代理草稿时须先应用或放弃。

界面将启动参数保存到应用数据目录中的 `database.properties`（macOS 为 `~/Library/Application Support/NetworkUI/database.properties`）。该文件由界面管理，密码以明文保存；macOS/Linux 权限为仅当前用户读写，Windows 使用当前用户 ACL。密码不写入启动命令或管理 API。

连接失败时保留本次选择并显示错误，不自动切回其他数据库。可重新打开数据库设置修改，或手动选择原 SQLite 文件/远程库恢复。原库的数据保留，不自动迁移。界面再次启动也使用已保存的选择。

## 切换与事务

切换数据库后读取选中库的配置和记录。新空库以空连接、空规则开始，不自动复制原库数据。原 SQLite 文件或远程数据库保留；再次指定原后端即可读取其中数据。没有数据迁移、双写或失败后退回 SQLite 的逻辑。

同一库只能由一个内核实例持有。SQLite 使用文件锁；PostgreSQL 使用会话 advisory lock；MySQL 使用命名锁。配置更改、版本递增和路由更新在同一事务内完成，失败时回滚。关闭内核会撤销未提交事务并释放锁。

内核可初始化空库，并为当前格式的内核数据库补建独立分钟流量表；非空但不属于当前内核格式的数据库、缺表或未知格式版本会拒绝启动，不删除或修改已有表。MySQL 的建表语句会隐式提交；若首次初始化中断，可能保留不完整的表，须人工检查或换一个空库，内核不会自动清理。

历史记录仍由转发线程入队、控制线程批量写入；重复批次按请求 ID 或会话与分钟起点幂等保存（重试覆盖完整分钟值，不重复累加）。数据库不可用时待写入批次留在内存，队列已满或内核退出时可能丢失尚未保存的记录，状态中的 `historyStorage` 会显示错误和丢弃数量。远程数据库连接断开后需要重启内核；不会自动重连，以免丢失独占锁后继续写入。

TUN 不针对数据库地址设置自动排除。数据库请求仍遵循现有系统路由与代理规则；JDBC 连接未绑定真实出口接口。远程数据库与 TUN 同时使用时，需要自行确保数据库可达，避免数据库连接依赖内核代理。数据库延迟或断网会影响管理操作和历史写入。

## 验证

本地回归包含 SQLite 当前格式读取、完整配置与凭据保存、事务回滚、历史筛选和分页、毫秒时间与大计数、字面子串搜索、批次幂等及启动参数检查。

远程集成测试入口共用同一套行为断言，必须提供**独立空测试库**。测试会写入配置和历史，并最终把该测试库的格式版本设为 99 来验证拒绝未知版本；数据会保留供检查，下次测试需要新的空库。未提供配置时对应测试显式跳过，不代表该后端已经实测。

```sh
NETWORK_TEST_POSTGRESQL_CONFIG=/测试目录/pg.properties \
NETWORK_TEST_MYSQL_CONFIG=/测试目录/mysql.properties \
mvn -pl ClientG -am -Dtest=DatabaseBackendsTest \
  -Dsurefire.failIfNoSpecifiedTests=false test
```

测试读取配置后会在建表前确认数据库为空，拒绝使用已有业务库。MySQL 和 PostgreSQL 驱动随 JAR 打包，不需另行安装 JDBC 驱动。

## 分钟流量表与中文备注

`traffic_minutes`：分钟业务流量统计，按运行会话与自然分钟保存增量。SQLite 的备注写在建表 SQL 中，可查询 `sqlite_schema.sql`；PostgreSQL 使用表及列的 `COMMENT ON`，MySQL 使用表及列的 `COMMENT`，数据库管理工具可直接查看。

| 字段 | 类型 | 中文备注 |
| --- | --- | --- |
| `id` | 整数自增主键 | 分钟流量记录主键 |
| `session_id` | VARCHAR(255) | 本次代理服务运行的唯一标识 |
| `minute_start` | BIGINT | 统计分钟起点，Unix 毫秒 |
| `active_duration_ms` | BIGINT | 本次运行在该分钟内的统计时长，毫秒 |
| `sent_bytes` | BIGINT | 该分钟上传业务字节数，非启动累计值 |
| `received_bytes` | BIGINT | 该分钟下载业务字节数，非启动累计值 |

唯一约束为 `(session_id, minute_start)`，另有 `minute_start` 时间索引。分钟起点必须是非负整分钟，时长为 0～60000 毫秒，字节数不得为负。极短连接可能不足一毫秒但已有字节，因此允许时长为零。

服务正常停止保存最后不足一分钟的记录；同一分钟多次启停按不同会话保存，界面按分钟相加。实际字节在读写发生时归属分钟，不用瞬时速率估算流量。平均速率可用字节数除以实际统计时长计算，时长为零时不计算速率。

旧 `traffic_samples` 不迁移、不读取、不合并、不删除，也不再新增记录。新的空数据库不创建该旧表。概览最近一小时的秒级数据仅保存在运行内核的内存中，UI 重连可恢复；重启内核后通过历史流量查看已保存分钟数据。异常退出可能丢失最后未完成分钟，数据库不可用时还可能丢失排队尚未落库的记录。
