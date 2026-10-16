#!/bin/sh
# 构建或测试双组件 TUN 辅助程序；Outline 补丁只作用于本次构建副本，不修改 Go 共享缓存。
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_ROOT/scripts/build-tools.sh"
load_build_tools "$PROJECT_ROOT"
MODE=${1:-build}
case "$MODE" in build|--test|--bench|--measure-ack|--build-test-binary) ;; *) printf '%s\n' '用法：sh scripts/build-tun.sh [--test|--bench|--measure-ack|--build-test-binary]' >&2; exit 1 ;; esac
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' '虚拟网卡辅助程序目前只支持在 macOS 构建。' >&2
  exit 1
fi
mkdir -p "$PROJECT_ROOT/target"
BUILD_DIR=$(mktemp -d "$PROJECT_ROOT/target/tun-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
cd "$PROJECT_ROOT/TunBridge"
printf '%s\n' '正在校验并准备固定版本的 TUN 依赖…'
"$GO" mod download github.com/eycorsican/go-tun2socks
DEPENDENCY_VERSION=$("$GO" list -m -f '{{.Version}}' github.com/eycorsican/go-tun2socks)
if [ "$DEPENDENCY_VERSION" != v1.16.11 ]; then
  printf '%s\n' 'TUN 依赖版本已变化，必须先复核补丁。' >&2
  exit 1
fi
DEPENDENCY_DIR=$("$GO" list -m -f '{{.Dir}}' github.com/eycorsican/go-tun2socks)
cp -R "$DEPENDENCY_DIR" "$BUILD_DIR/go-tun2socks"
chmod -R u+w "$BUILD_DIR/go-tun2socks"
if ! patch --batch --fuzz=0 -p1 -d "$BUILD_DIR/go-tun2socks" < patches/go-tun2socks-v1.16.11.patch > "$BUILD_DIR/patch.log" 2>&1; then
  printf '%s\n' '应用 TUN 依赖补丁失败：' >&2
  cat "$BUILD_DIR/patch.log" >&2
  exit 1
fi
cp go.mod "$BUILD_DIR/tun.mod"
cp go.sum "$BUILD_DIR/tun.sum"
"$GO" mod edit -modfile="$BUILD_DIR/tun.mod" -replace="github.com/eycorsican/go-tun2socks=$BUILD_DIR/go-tun2socks"
if [ "$MODE" = --measure-ack ]; then
  printf '%s\n' '正在测量真实 TCP 转发与 ACK 延迟…'
  CGO_ENABLED=1 "$GO" test -modfile="$BUILD_DIR/tun.mod" -mod=readonly -c -o "$BUILD_DIR/ack.test" .
  NETWORK_ACK_OUTPUT="${NETWORK_ACK_OUTPUT:-direct}" python3 "$PROJECT_ROOT/scripts/measure-tun-ack.py" "$BUILD_DIR/ack.test"
  NETWORK_ACK_MEASURE=1 NETWORK_ACK_OUTPUT="${NETWORK_ACK_OUTPUT:-direct}" "$BUILD_DIR/ack.test" -test.run '^TestTCPSinglePacketACKLatency$' -test.v -test.timeout 10s
elif [ "$MODE" = --build-test-binary ]; then
  printf '%s\n' '正在生成用于真实 utun 诊断的测试程序…'
  CGO_ENABLED=1 "$GO" test -modfile="$BUILD_DIR/tun.mod" -mod=readonly -c -o "$PROJECT_ROOT/target/tun.test" .
  printf '测试程序已生成：%s\n' "$PROJECT_ROOT/target/tun.test"
elif [ "$MODE" = --bench ]; then
  printf '%s\n' '正在测量 TUN TCP 在模拟确认延迟下的吞吐…'
  CGO_ENABLED=1 "$GO" test -modfile="$BUILD_DIR/tun.mod" -mod=readonly -run '^$' -bench '^(BenchmarkTCPUpload|BenchmarkTUNWrite)$' -benchmem -benchtime=3x -count=3 -timeout 60s .
elif [ "$MODE" = --test ]; then
  printf '%s\n' '正在测试 TUN 辅助程序（Outline SDK 与 xjasonlyu/tun2socks）…'
  CGO_ENABLED=1 "$GO" test -modfile="$BUILD_DIR/tun.mod" -mod=readonly -race -timeout 60s ./...
else
  printf '%s\n' '正在构建双组件虚拟网卡辅助程序…'
  CGO_ENABLED=1 "$GO" build -modfile="$BUILD_DIR/tun.mod" -mod=readonly -trimpath -o "$PROJECT_ROOT/target/network-tun" .
  printf '辅助程序已生成：%s\n' "$PROJECT_ROOT/target/network-tun"
fi
