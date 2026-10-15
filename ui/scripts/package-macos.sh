#!/bin/sh
# 生成包含 AOT 原生内核的 macOS 应用；仅构建当前机器架构。
set -eu
BUILD_TIMESTAMP=$(TZ=Asia/Shanghai date '+%Y%m%d-%H%M%S')
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=$(CDPATH= cd -- "${CORE_ROOT:-"$UI_ROOT/.."}" && pwd)
. "$CORE_ROOT/scripts/build-tools.sh"
load_build_tools "$CORE_ROOT"
if [ "$#" -ne 0 ]; then
  printf '%s\n' '打包脚本不接受输出路径参数，应用输出到 release/ui/Network-年月日-时分秒.app。' >&2
  exit 1
fi
OUTPUT="$CORE_ROOT/release/ui/Network-$BUILD_TIMESTAMP.app"
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '同名应用已存在，停止打包以保留已有产物：%s\n' "$OUTPUT" >&2
  exit 1
fi
mkdir -p "$UI_ROOT/build"
PACKAGE_DIR=$(mktemp -d "$UI_ROOT/build/package-macos.XXXXXX")
trap 'rm -rf "$PACKAGE_DIR"' EXIT HUP INT TERM
STAGED_APP="$PACKAGE_DIR/Network.app"
if [ -z "${NATIVE_CORE:-}" ]; then
  printf '%s\n' '正在构建原生代理内核…'
  sh "$CORE_ROOT/scripts/build-native.sh"
  NATIVE_CORE="$CORE_ROOT/ClientG/target/native/network-core"
fi
if [ ! -x "$NATIVE_CORE" ]; then
  printf '原生内核不存在或不可执行：%s\n' "$NATIVE_CORE" >&2
  exit 1
fi
printf '%s\n' '正在构建 macOS 界面…'
(cd "$UI_ROOT" && "$FLUTTER" build macos --release)
ditto "$UI_ROOT/build/macos/Build/Products/Release/network_ui.app" "$STAGED_APP"
ASSETS="$STAGED_APP/Contents/Resources/proxy"
mkdir -p "$ASSETS"
sh "$CORE_ROOT/scripts/build-tun.sh"
cp "$CORE_ROOT/target/network-tun" "$ASSETS/network-tun"
ditto "$CORE_ROOT/TunBridge/licenses" "$ASSETS/tun-licenses"
cp "$NATIVE_CORE" "$ASSETS/network-core"
# GraalVM 可能在程序旁输出所需的动态库，一并打包并参与签名。
for library in "$(dirname "$NATIVE_CORE")"/*.dylib; do
  [ ! -f "$library" ] || cp "$library" "$ASSETS/"
done
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
printf '%s\n' "应用已生成：$OUTPUT" '应用使用本机临时签名；公开分发前需使用 Developer ID 签名并公证。'
printf '[打开 UI 所在文件夹](<%s/release/ui/>)\n' "$CORE_ROOT"
