#!/bin/sh
# 构建或测试 Outline 辅助程序；补丁只作用于本次构建副本，不修改 Go 共享缓存。
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GO=${GO:-go}
MODE=${1:-build}
case "$MODE" in build|--test) ;; *) printf '%s\n' '用法：sh scripts/build-tun.sh [--test]' >&2; exit 1 ;; esac
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
if [ "$MODE" = --test ]; then
  printf '%s\n' '正在测试包含补丁的 Outline 辅助程序…'
  CGO_ENABLED=1 "$GO" test -modfile="$BUILD_DIR/tun.mod" -mod=readonly -race -timeout 60s ./...
else
  printf '%s\n' '正在构建 Outline 虚拟网卡辅助程序…'
  CGO_ENABLED=1 "$GO" build -modfile="$BUILD_DIR/tun.mod" -mod=readonly -trimpath -o "$PROJECT_ROOT/target/network-tun" .
  printf '辅助程序已生成：%s\n' "$PROJECT_ROOT/target/network-tun"
fi
