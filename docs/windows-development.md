# Windows 开发与打包

Windows x64 使用同一套 Flutter 界面与 Java 25 内核。主窗口关闭后留在托盘；托盘菜单“退出 Orbi”会先停止内核和 TUN，再退出应用。Windows 使用便携模式，配置、数据库、日志和运行信息统一存放在 `Orbi.exe` 同级的 `data/`；Flutter 静态资源在 `resources/flutter/`。macOS 的目录规则保持不变。

数据目录取自实际可执行文件的位置，不依赖启动工作目录或快捷方式的“起始位置”。程序文件夹需要可写；不可写时明确报错，不回退到 AppData。保存连接时，外部 CA 证书复制到 `data/certs/`，数据库保存相对路径；SQLite 启动配置也保存相对于 `data/` 的路径，不能选择目录外的 SQLite 文件。移动时携带整个程序文件夹，升级时保留 `data/`。

## 显式迁移现有数据

先保存草稿并从托盘退出旧版，再执行一次迁移：

```powershell
python3 scripts/migrate-windows-data.py --source "$env:LOCALAPPDATA\Orbi" --bundle "Q:\dev\project\Orbi\release\ui\实际新版目录"
```

迁移入口只处理当前 SQLite 数据格式，将数据库、界面设置、日志和引用的 CA 证书复制到目标包的 `data/`，保留连接凭据、路由和历史记录。源数据始终保留，目标已有内容或源库仍被占用时停止；不复制旧锁文件、控制接口发现文件和事务日志。新版不会自动读取或同步 AppData。常规打包只创建空 `data/`，不会把个人数据混入每次构建。

从 MSIX 打包宿主启动的工具可能读到 Windows 重定向后的 AppData 副本。迁移前核对源库连接数量与实际客户端一致；若不一致，先从资源管理器将真实数据复制到普通目录，再将该目录作为 `--source`。不要将空副本误作正在使用的数据。

## 工具链

安装 JDK 25、Maven、Go、Flutter、Python 3、Visual Studio 的“使用 C++ 的桌面开发”工作负载及 Windows SDK。TUN 的 Outline SDK 还需要 C 编译器，可使用 Zig。Git for Windows 的 `bin` 和 `usr/bin` 需在 PATH 中，供构建入口调用 `sh` 和 `patch`。

在项目根目录创建不提交的 `build.local.properties`，Git Bash 下使用 `/q/...` 路径，例如：

```properties
java.home=/q/dev/toolchains/jdk-25.0.4.1+1
maven.bin=/q/dev/toolchains/apache-maven-3.9.16/bin/mvn
go.bin=/q/dev/toolchains/go-1.27.2/bin/go.exe
flutter.bin=/q/dev/toolchains/flutter-3.47.6/bin/flutter
cc.bin=/q/dev/toolchains/zig-x86_64-windows-0.17.0/zig.exe
wintun.home=/q/dev/toolchains/wintun-0.14.1/wintun
```

所有构建入口加载 `scripts/build-tools.sh`，工具路径优先使用环境变量，其次使用本机配置。Maven 镜像配置放在用户 `.m2/settings.xml`；本项目没有 npm 依赖。

从 [Wintun 官方网站](https://www.wintun.net/) 下载 0.14.1 并解压，ZIP 的 SHA256 为 `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`。`wintun.home` 指向包含 `LICENSE.txt` 和 `bin` 的目录。打包时检查 AMD64 DLL 的 WireGuard 数字签名，并保留其授权文件。

## 构建与验证

在项目根目录运行：

```sh
mvn -B -ntp test
sh scripts/build-tun.sh --test
python3 -m unittest discover -s scripts/tests -p test_build_tools.py
cd ui
flutter analyze
flutter test
cd ..
sh scripts/package-windows.sh
```

打包使用 JAR 模式，不执行 GraalVM Native Image。UI 产物在 `release/ui/Orbi-YYYYMMDD-HHMMSS/`，包含 `Orbi.exe`、Flutter 文件、Visual C++ 运行库，以及 `proxy/` 下的客户端 JAR、Java 运行时、TUN 辅助程序和官方 Wintun DLL。启动时无需另外安装 Java。已有 UI 包保持不变；独立 JAR 更新到 `release/client/client.jar` 与 `release/server/server.jar`。

用户明确要求 AOT 时，在本机配置添加 `graalvm.home=/q/dev/toolchains/实际的GraalVM目录`，再执行 `sh scripts/package-windows.sh --native`。该入口使用 GraalVM 与已安装的 MSVC 将客户端编译为 `network-core.exe`，应用包保留必要的原生 DLL，不包含客户端 JAR 或 Java 运行时。独立原生内核位于 `ClientG/target/native/`，也可单独执行 `sh scripts/build-native.sh`。服务端继续使用 JAR；默认打包入口仍不自动触发 AOT。

## TUN

Windows 每次开启 TUN 都通过系统 UAC 启动当前会话的辅助进程，不安装常驻提权服务。Wintun 提供 IP 报文通道，Outline SDK 或 tun2socks 通过现有本机代理协议转发 TCP/UDP；Java 套接字绑定真实接口的 `IP_UNICAST_IF` / `IPV6_UNICAST_IF`，避免出口再次进入 TUN。JNI 接口绑定库由 Maven 在 Windows 上编译并嵌入 JAR。

发现文件必须属于同一用户且没有其他普通用户可读权限；只接受回环 HTTP 管理接口。停止、客户端退出、内核失联或物理网络变化时关闭会话，移除所创建网卡和该网卡的路由，不修改真实网卡的默认路由。

规则模式下，内网地址也遵循当前路由规则；直连规则为空时会使用默认远端代理，远端无法访问本机局域网时会返回 502。需要访问本机和私网时，在现有直连规则中添加 `127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`::1/128` 和 `fc00::/7`。这属于用户路由配置，内核不会暗中绕过指定目标或全局代理模式。

正常退出先请求 `tun/stop`，保留内核管理接口，等待辅助程序关闭网卡和路由并完成 `tun/finish`，再请求 `kernel/shutdown`。清理超时或失败时取消本次退出并保留重试能力，不能先关闭内核再把辅助程序的连接失败当作成功退出。

真实 Wintun 测试需单独授权，普通 Go 测试不会修改系统网络。在 Git Bash 生成测试程序：

```sh
sh scripts/build-tun.sh --build-test-binary
```

将官方 `wintun.dll` 复制到 `target/` 后，在管理员 PowerShell 中运行：

```powershell
& .\target\tun.test.exe -test.run TestWindowsWintunLive -test.v -test.timeout 120s -orbi-wintun-live
```

测试仅添加保留测试网段的路由，检查两个组件的 IPv4/IPv6 TCP/UDP 收发以及关闭后的路由清理；结果写入 `target/wintun-live-result.json`。这与实际 UI 的 UAC 启动和系统默认流量接管应分别验证。
