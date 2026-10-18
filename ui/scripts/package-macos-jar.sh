#!/bin/sh
# 使用 JAR 与内置 Java 运行时生成应用，不执行 Native Image 编译。
set -eu
BUILD_TIMESTAMP=$(TZ=Asia/Shanghai date '+%Y%m%d-%H%M%S')
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=$(CDPATH= cd -- "${CORE_ROOT:-"$UI_ROOT/.."}" && pwd)
. "$CORE_ROOT/scripts/build-tools.sh"
load_build_tools "$CORE_ROOT"
if [ "$#" -ne 0 ]; then
  printf '%s\n' '打包脚本不接受输出路径参数，应用输出到 release/ui/Orbi-年月日-时分秒.app。' >&2
  exit 1
fi
OUTPUT="$CORE_ROOT/release/ui/Orbi-$BUILD_TIMESTAMP.app"
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '同名应用已存在，停止打包以保留已有产物：%s\n' "$OUTPUT" >&2
  exit 1
fi
mkdir -p "$UI_ROOT/build"
PACKAGE_DIR=$(mktemp -d "$UI_ROOT/build/package-macos.XXXXXX")
trap 'rm -rf "$PACKAGE_DIR"' EXIT HUP INT TERM
STAGED_APP="$PACKAGE_DIR/Orbi.app"
if [ ! -x "$JDK_HOME/bin/jlink" ]; then
  printf '%s\n' '请在 build.local.properties 的 java.home 或 JDK_HOME 中指定 Java 25 JDK。' >&2
  exit 1
fi
printf '%s\n' '正在构建客户端和服务端 JAR…'
(cd "$CORE_ROOT" && JAVA_HOME="$JDK_HOME" "$MVN" -q -DskipTests package)
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
# 构建和签名通过后发布新包，保留已有版本；UI 运行数据保存在 Application Support/NetworkUI。
mkdir -p "$(dirname "$OUTPUT")"
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '同名应用已存在，停止发布以保留已有产物：%s\n' "$OUTPUT" >&2
  exit 1
fi
mv "$STAGED_APP" "$OUTPUT"
mkdir -p "$CORE_ROOT/release/client" "$CORE_ROOT/release/server"
cp "$CORE_ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" "$CORE_ROOT/release/client/client.jar"
cp "$CORE_ROOT/Server/target/Server-1.0-SNAPSHOT.jar" "$CORE_ROOT/release/server/server.jar"
printf '应用已生成：%s\n' "$OUTPUT"
printf 'JAR 已更新：%s/release/client/client.jar、%s/release/server/server.jar\n' "$CORE_ROOT" "$CORE_ROOT"
printf '[打开 UI 所在文件夹](<%s/release/ui/>)\n' "$CORE_ROOT"
printf '[打开客户端所在文件夹](<%s/release/client/>)\n' "$CORE_ROOT"
printf '[打开服务端所在文件夹](<%s/release/server/>)\n' "$CORE_ROOT"
printf '%s\n' '应用内置 JAR 与 Java 运行时，使用本机临时签名。'
