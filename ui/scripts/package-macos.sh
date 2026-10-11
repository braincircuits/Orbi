#!/bin/sh
# 生成包含 AOT 原生内核的 macOS 应用；仅构建当前机器架构。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${CORE_ROOT:-"$UI_ROOT/.."}
FLUTTER=${FLUTTER:-flutter}
OUTPUT=${1:-"$UI_ROOT/dist/Network.app"}
if [ -e "$OUTPUT" ]; then
  printf '%s\n' "输出目录已存在，拒绝覆盖：$OUTPUT" >&2
  exit 1
fi
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
mkdir -p "$(dirname "$OUTPUT")"
ditto "$UI_ROOT/build/macos/Build/Products/Release/network_ui.app" "$OUTPUT"
ASSETS="$OUTPUT/Contents/Resources/proxy"
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
codesign --force --deep --sign - "$OUTPUT"
codesign --verify --deep --strict "$OUTPUT"
printf '%s\n' "应用已生成：$OUTPUT" '应用使用本机临时签名；公开分发前需使用 Developer ID 签名并公证。'
