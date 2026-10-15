#!/bin/sh
# 使用 JAR 与内置 Java 运行时生成应用，不执行 Native Image 编译。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${CORE_ROOT:-"$UI_ROOT/.."}
FLUTTER=${FLUTTER:-flutter}
JDK_HOME=${JDK_HOME:-${JAVA_HOME:-}}
if [ "$#" -ne 0 ]; then
  printf '%s\n' '打包脚本不接受输出路径参数，应用固定输出到 release/ui/Network.app。' >&2
  exit 1
fi
OUTPUT="$CORE_ROOT/release/ui/Network.app"
mkdir -p "$UI_ROOT/build"
PACKAGE_DIR=$(mktemp -d "$UI_ROOT/build/package-macos.XXXXXX")
trap 'rm -rf "$PACKAGE_DIR"' EXIT HUP INT TERM
STAGED_APP="$PACKAGE_DIR/Network.app"
if [ ! -x "$JDK_HOME/bin/jlink" ]; then
  printf '%s\n' '请通过 JDK_HOME 指定 Java 25 JDK。' >&2
  exit 1
fi
printf '%s\n' '正在构建客户端和服务端 JAR…'
(cd "$CORE_ROOT" && JAVA_HOME="$JDK_HOME" mvn -q -DskipTests package)
sh "$CORE_ROOT/scripts/build-tun.sh"
printf '%s\n' '正在构建 macOS 界面…'
(cd "$UI_ROOT" && "$FLUTTER" build macos --release -t lib/main.dart)
ditto "$UI_ROOT/build/macos/Build/Products/Release/network_ui.app" "$STAGED_APP"
ASSETS="$STAGED_APP/Contents/Resources/proxy"
mkdir -p "$ASSETS"
cp "$CORE_ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" "$ASSETS/client.jar"
cp "$CORE_ROOT/target/network-tun" "$ASSETS/network-tun"
ditto "$CORE_ROOT/TunBridge/licenses" "$ASSETS/tun-licenses"
printf '%s\n' '正在生成内置 Java 运行时…'
"$JDK_HOME/bin/jlink" --add-modules java.se,jdk.httpserver,jdk.jfr,jdk.unsupported,jdk.crypto.ec,jdk.naming.dns \
  --strip-debug --no-header-files --no-man-pages --output "$ASSETS/runtime"
# 与开发环境使用相同的 Gson 数字写入定点规避，启动器不依赖外部 Java 或绝对路径。
cat > "$ASSETS/network-core" <<'LAUNCHER'
#!/bin/sh
set -eu
KERNEL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$KERNEL_ROOT/runtime/bin/java" --enable-native-access=ALL-UNNAMED \
  -XX:CompileCommand=quiet \
  '-XX:CompileCommand=exclude,com/google/gson/stream/JsonWriter.value,(J)Lcom/google/gson/stream/JsonWriter;' \
  -jar "$KERNEL_ROOT/client.jar" "$@"
LAUNCHER
chmod 755 "$ASSETS/network-core"
printf '%s\n' '正在进行本机临时签名…'
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
# 构建和签名通过后才替换应用；UI 运行数据保存在 Application Support/NetworkUI。
mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"
mv "$STAGED_APP" "$OUTPUT"
mkdir -p "$CORE_ROOT/release/client" "$CORE_ROOT/release/server"
cp "$CORE_ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" "$CORE_ROOT/release/client/client.jar"
cp "$CORE_ROOT/Server/target/Server-1.0-SNAPSHOT.jar" "$CORE_ROOT/release/server/server.jar"
printf '应用已生成：%s\n' "$OUTPUT"
printf 'JAR 已更新：%s/release/client/client.jar、%s/release/server/server.jar\n' "$CORE_ROOT" "$CORE_ROOT"
printf '%s\n' '应用内置 JAR 与 Java 运行时，使用本机临时签名。'
