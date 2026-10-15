# 本机构建工具配置

项目的依赖版本继续由 `pom.xml`、`TunBridge/go.mod`、`go.sum`、`ui/pubspec.yaml` 和 `pubspec.lock` 管理。本机工具的安装路径集中在项目根目录 `build.local.properties`，该文件已加入 Git 忽略规则。

## 首次配置

在项目根目录执行，然后按本机安装位置修改：

```sh
cp examples/build.properties build.local.properties
```

示例：

```properties
java.home=~/.sdkman/candidates/java/current
maven.bin=~/.sdkman/candidates/maven/current/bin/mvn
go.bin=~/O/toolchains/go-1.27.2/bin/go
flutter.bin=~/O/toolchains/flutter/bin/flutter
# graalvm.home=/实际路径/graalvm-25
```

| 配置项 | 内容 | 可覆盖它的环境变量 |
| --- | --- | --- |
| `java.home` | JDK 25 安装目录，不是 java 可执行文件 | `JDK_HOME`，其次为 `JAVA_HOME` |
| `maven.bin` | Maven 可执行文件路径 | `MVN` |
| `go.bin` | Go 可执行文件路径 | `GO` |
| `flutter.bin` | Flutter 可执行文件路径 | `FLUTTER` |
| `graalvm.home` | 可选，GraalVM 安装目录，仅明确执行原生构建时使用 | `GRAALVM_HOME` |

优先级为：**非空环境变量 → 非空本机配置 → 原有默认值**。Maven、Go 和 Flutter 默认从 PATH 查找；Java 没有配置时，普通构建沿用终端环境，JAR 模式 UI 打包仍要求明确指定 JDK 目录以运行 jlink。GraalVM 未指定时使用选定的 JDK 目录，执行原生构建时会检查 native-image 是否存在。填写 GraalVM 路径不会触发 AOT 编译。

配置文件按文本解析，不作为 Shell 执行。每行一个 `键=值`，在第一个 `=` 处分隔；忽略空行、行首 `#` 注释和键值两端空白。支持 LF、CRLF 和末行无换行。路径不加外层引号，支持空格、`~/` 和以仓库根目录为基准的相对路径。不做 `$变量` 替换或命令替换；不支持行尾注释、续行和 Unicode 转义。未知或重复字段会报错；可选字段允许留空。

脚本从项目根目录读取配置，与执行时的工作目录无关。选定的工具路径会导出给子构建脚本；选定 JDK 同时用于 Maven 和构建过程中的 Java 命令。临时切换工具可以使用 `GO=/其他路径/bin/go sh scripts/build-tun.sh`，无需修改配置。

## 自动读取配置的入口

- `scripts/package-release.sh`：构建并测试客户端、服务端 JAR。
- `scripts/build-tun.sh`：构建 TUN 辅助程序，`--test` 运行相关测试。
- `scripts/build-native.sh`：仅按明确的 AOT 编译请求执行。
- `ui/scripts/package-macos-jar.sh`：JAR 模式 UI 打包，同时更新两个独立 JAR。
- `ui/scripts/package-macos.sh`：仅按明确的 Native Image 打包请求执行。
- `ui/scripts/run-dev.sh`：构建内核及 TUN 辅助程序，启动开发 UI。
- `ui/scripts/test-macos-sidebar.sh`：运行 macOS 侧栏原生交互测试。

这些入口复用 `scripts/build-tools.sh`，不自动安装或下载工具链。直接运行 `mvn`、`go`、`flutter` 时不会读取本配置，仍由当前终端环境决定工具位置。

## 固定工具链与依赖缓存

本机 Go 1.27.2 已从临时目录移至 `/Users/blacicada/O/toolchains/go-1.27.2`，本机配置指向其中的 `bin/go`。Flutter 沿用 `/Users/blacicada/O/toolchains/flutter`；Java 和 Maven 沿用 SDKMAN 安装目录。工具链采用固定目录，避免临时目录清理导致构建环境缺失。

Go 工具链和项目依赖是不同内容。此次移动不修改 Go 的缓存配置：模块通常位于 `~/go/pkg/mod`，下载缓存位于其 `cache/download` 下；macOS 编译缓存通常位于 `~/Library/Caches/go-build`。实际目录以所选 Go 的 `go env GOMODCACHE GOCACHE` 输出为准。

本机配置加载回归检查：

```sh
python3 -m unittest discover -s scripts/tests -p 'test_build_tools.py'
```
