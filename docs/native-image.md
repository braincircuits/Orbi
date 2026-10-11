# GraalVM 原生代理内核

`ClientG` 可用 GraalVM 25 Native Image 把完整 JAR AOT 编译为本机原生程序。启动参数、Web API、数据库和代理协议保持一致。发布时直接运行程序，无需安装 Java，也不通过脚本再启动 JAR。

仅在用户明确要求 AOT / Native Image 编译时执行下述构建命令。日常开发验证使用 JAR，不自动触发原生编译。

## 构建和运行

```sh
GRAALVM_HOME=/实际路径/graalvm-25 sh scripts/build-native.sh
ClientG/target/native/network-core --web --db /配置绝对路径/kernel.db --port 0 --endpoint-file /配置绝对路径/run/control.json
```

macOS 需要 Xcode 命令行工具。`GRAALVM_HOME` 默认读取 `JAVA_HOME`，要求该目录包含 `native-image`；`MAVEN_OFFLINE=1` 仅使用本地 Maven 缓存。构建输出在 `ClientG/target/native/`，第一个脚本参数可指定其他输出位置。构建阶段限制为 6 GB Java 堆和 6 个线程。

发布时保留程序旁的 GraalVM 动态库，例如 macOS 的 `libmanagement_ext.dylib`。Netty QUIC 和 DNS 原生库作为资源嵌入程序，由 Netty 在运行时加载。构建结果只适用于对应操作系统和 CPU 架构，不是跨平台可执行文件。本次验证环境为 macOS arm64、GraalVM CE 25.4.4.1.1、Netty 4.2.18.Final。

Netty、Log4j 和 Disruptor 在运行时初始化，避免将构建机的日志上下文、线程和网络状态写入原生程序。原生程序不接受 `-jar` 或 JVM 的 `CompileCommand` 参数。

## 验证

```sh
PATH="$GRAALVM_HOME/bin:$PATH" \
UI_TEST_JAVA="$GRAALVM_HOME/bin/java" \
NATIVE_CORE="$PWD/ClientG/target/native/network-core" \
python3 scripts/web-smoke-test.py
```

测试使用临时目录、本机代理服务端和仓库测试证书，验证 HTTP/2、HTTP/3、普通 HTTP、CONNECT、TLS、异步诊断、直连规则、SQLite 自动保存与路由导入导出及退出清理。代理服务端仍使用 JAR，`NATIVE_CORE` 仅指定被测代理内核。未设置该变量时，同一个测试验证 JAR 内核。

Flutter 项目通过 `--dart-define=PROXY_NATIVE=/原生程序绝对路径` 运行真实 UI 联调；`NATIVE_CORE` 配合 `test/native_kernel_integration_test.dart` 验证应用资源内原生程序的发现、自动启动、保存配置和重新接管。

## 反射与 JNI 元数据

元数据在 `ClientG/src/main/resources/META-INF/native-image/com.blacicada/client/reachability-metadata.json`，由 GraalVM tracing agent 采集并合并。采集范围是 Flutter 项目的 `core_integration_test.dart` 和 `multi_connection_integration_test.dart`：配置、路由、隧道、日志、SSE、持久化、诊断、HTTP/2 TLS、HTTP/3 QUIC 以及直连。未通过测试框架收集 JUnit 内部反射信息。

更新动态加载逻辑、依赖或目标平台时，需重新采集并执行原生联调。采集时只对客户端 JAR 添加 agent，服务端使用普通 JVM；每个内核进程分别输出，避免多个进程覆盖同一目录：

```sh
"$GRAALVM_HOME/bin/java" \
  -agentlib:native-image-agent=config-output-dir=/临时目录/run-进程编号 \
  --enable-native-access=ALL-UNNAMED \
  -jar ClientG/target/clientG-1.0-SNAPSHOT.jar --web \
  --db /临时目录/kernel.db --port 0 --endpoint-file /临时目录/control.json
```

可在 UI 联调的 `UI_TEST_JAVA` 包装脚本中按客户端 JAR 名称添加上述 agent 参数。完整执行管理操作和两种协议后，通过 `native-image-utils generate --input-dir=目录1 --input-dir=目录2 --output-dir=元数据目录` 合并。检查采集内容，确保没有用户配置、密码、令牌或本机绝对路径，然后重新编译和验证。Agent 只能记录执行过的分支；编译成功不能替代实际协议测试。

官方参考：[Tracing Agent](https://www.graalvm.org/latest/reference-manual/native-image/metadata/AutomaticMetadataCollection/)。

SQLite 驱动使用 [Xerial sqlite-jdbc](https://github.com/xerial/sqlite-jdbc) 3.53.4.0，自带 Native Image 支持与原生库资源。省略 `--db` 时数据库创建在实际原生可执行程序同目录，而不是启动工作目录。该目录不可写时需显式指定可写数据库路径。
