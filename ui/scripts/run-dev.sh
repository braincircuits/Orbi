#!/bin/sh
# 构建 Java 内核并运行 macOS 桌面界面。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${CORE_ROOT:-"$UI_ROOT/.."}
FLUTTER=${FLUTTER:-flutter}
JAVA_BIN=${JAVA_HOME:+"$JAVA_HOME/bin/java"}
JAVA_BIN=${JAVA_BIN:-$(command -v java)}
printf '%s\n' '正在构建代理内核…'
(cd "$CORE_ROOT" && mvn -q -DskipTests package)
sh "$CORE_ROOT/scripts/build-tun.sh"
cd "$UI_ROOT"
exec "$FLUTTER" run -d macos --dart-define="PROXY_JAR=$CORE_ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" --dart-define="JAVA_PATH=$JAVA_BIN" --dart-define="PROXY_TUN=$CORE_ROOT/target/network-tun"
