#!/bin/sh
# 构建 Java 内核并运行 macOS 桌面界面。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=$(CDPATH= cd -- "${CORE_ROOT:-"$UI_ROOT/.."}" && pwd)
. "$CORE_ROOT/scripts/build-tools.sh"
load_build_tools "$CORE_ROOT"
JAVA_BIN=${JAVA_HOME:+"$JAVA_HOME/bin/java"}
JAVA_BIN=${JAVA_BIN:-$(command -v java)}
printf '%s\n' '正在构建代理内核…'
(cd "$CORE_ROOT" && "$MVN" -q -DskipTests package)
sh "$CORE_ROOT/scripts/build-tun.sh"
cd "$UI_ROOT"
exec "$FLUTTER" run -d macos --dart-define="PROXY_JAR=$CORE_ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" --dart-define="JAVA_PATH=$JAVA_BIN" --dart-define="PROXY_TUN=$CORE_ROOT/target/network-tun"
