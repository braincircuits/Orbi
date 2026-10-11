#!/bin/sh
set -eu
umask 077
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v python3 >/dev/null
if [ ! -f "$project_dir/ClientG/target/clientG-1.0-SNAPSHOT.jar" ]; then
    printf '%s\n' '请先执行 mvn -DskipTests package 构建内核 JAR。' >&2
    exit 1
fi
config_dir=${1:-.local-h3}
if [ -e "$config_dir" ]; then
    echo "拒绝覆盖已有目录：$config_dir" >&2
    exit 1
fi
mkdir -p "$config_dir"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$config_dir/server.key" -out "$config_dir/server.crt" \
    -days 365 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
secret=$(openssl rand -hex 32)
cat > "$config_dir/server.properties" <<CONFIG
bind=127.0.0.1
port=4433
password=$secret
tls.cert=server.crt
tls.key=server.key
CONFIG
printf '%s\n' "$secret" | python3 "$project_dir/scripts/initialize-kernel.py" \
    --jar "$project_dir/ClientG/target/clientG-1.0-SNAPSHOT.jar" \
    --db "$config_dir/kernel.db" --ca "$config_dir/server.crt"
printf '本机开发配置已生成：%s\n' "$config_dir"
