#!/bin/sh
# 使用 JAR 与内置 Java 运行时生成应用，不执行 Native Image 编译。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${CORE_ROOT:-"$UI_ROOT/.."}
FLUTTER=${FLUTTER:-flutter}
JDK_HOME=${JDK_HOME:-${JAVA_HOME:-}}
OUTPUT=${1:-"$UI_ROOT/dist/Network-JAR.app"}
if [ -e "$OUTPUT" ]; then
  printf '输出目录已存在，拒绝覆盖：%s\n' "$OUTPUT" >&2
  exit 1
fi
if [ ! -x "$JDK_HOME/bin/jlink" ]; then
  printf '%s\n' '请通过 JDK_HOME 指定 Java 25 JDK。' >&2
  exit 1
fi
printf '%s\n' '正在构建 JAR 代理内核…'
(cd "$CORE_ROOT" && JAVA_HOME="$JDK_HOME" mvn -q -pl ClientG -am -DskipTests package)
sh "$CORE_ROOT/scripts/build-tun.sh"
printf '%s\n' '正在构建 macOS 界面…'
(cd "$UI_ROOT" && "$FLUTTER" build macos --release -t lib/main.dart)
mkdir -p "$(dirname "$OUTPUT")"
ditto "$UI_ROOT/build/macos/Build/Products/Release/network_ui.app" "$OUTPUT"
ASSETS="$OUTPUT/Contents/Resources/proxy"
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
codesign --force --deep --sign - "$OUTPUT"
codesign --verify --deep --strict "$OUTPUT"
printf '应用已生成：%s\n' "$OUTPUT"
printf '%s\n' '应用内置 JAR 与 Java 运行时，使用本机临时签名。'
