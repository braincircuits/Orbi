#!/bin/sh
# 使用 GraalVM 25 把当前代理内核编译为本机架构的独立程序。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GRAALVM_HOME=${GRAALVM_HOME:-${JAVA_HOME:-}}
if [ -z "$GRAALVM_HOME" ] || [ ! -x "$GRAALVM_HOME/bin/native-image" ]; then
    printf '%s\n' '请设置 GRAALVM_HOME，指向包含 native-image 的 GraalVM 25。' >&2
    exit 1
fi
OUTPUT=${1:-"$ROOT/ClientG/target/native/network-core"}
mkdir -p "$(dirname "$OUTPUT")"
printf '%s\n' '正在构建代理内核 JAR…'
if [ "${MAVEN_OFFLINE:-0}" = 1 ]; then
    (cd "$ROOT" && JAVA_HOME="$GRAALVM_HOME" mvn -o -q -DskipTests package)
else
    (cd "$ROOT" && JAVA_HOME="$GRAALVM_HOME" mvn -q -DskipTests package)
fi
printf '%s\n' '正在使用 GraalVM 编译原生代理内核…'
"$GRAALVM_HOME/bin/native-image" -J-Xmx6g --parallelism=6 --enable-native-access=ALL-UNNAMED \
    --initialize-at-run-time=io.netty,org.apache.logging.log4j,com.lmax.disruptor \
    -jar "$ROOT/ClientG/target/clientG-1.0-SNAPSHOT.jar" -o "$OUTPUT"
printf '原生代理内核已生成：%s\n' "$OUTPUT"
