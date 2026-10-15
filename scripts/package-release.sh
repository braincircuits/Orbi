#!/bin/sh
# 构建并更新固定发布目录；已有配置、数据库和证书保持不变。
set -eu
umask 077
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 0 ]; then
    printf '%s\n' '用法：sh scripts/package-release.sh（产物固定输出到 release/client 和 release/server）' >&2
    exit 1
fi
release_dir="$project_dir/release"
# 只有客户端和服务端目录均不存在时才初始化新部署，UI 目录不影响判断。
initialize=true
if [ -e "$release_dir/client" ] || [ -e "$release_dir/server" ]; then
    initialize=false
fi
if [ "$initialize" = true ]; then
    command -v openssl >/dev/null
    command -v python3 >/dev/null
fi
(cd "$project_dir" && mvn -B -ntp package)
mkdir -p "$release_dir/client" "$release_dir/server"
cp "$project_dir/Server/target/Server-1.0-SNAPSHOT.jar" "$release_dir/server/server.jar"
cp "$project_dir/ClientG/target/clientG-1.0-SNAPSHOT.jar" "$release_dir/client/client.jar"
if [ "$initialize" = false ]; then
    printf '发布产物已更新：%s/client/client.jar、%s/server/server.jar\n' "$release_dir" "$release_dir"
    printf '%s\n' '已有配置、数据库、证书和启动脚本保持不变。'
    exit 0
fi
for app in server client; do
    mkdir -p "$release_dir/$app/config" "$release_dir/$app/certs"
    config_name=server.properties
    [ "$app" != client ] || config_name=kernel.db
    sed "s/@APP@/$app/g; s/@CONFIG@/$config_name/g" "$project_dir/scripts/release/start.sh.template" > "$release_dir/$app/start.sh"
    sed "s/@APP@/$app/g; s/@CONFIG@/$config_name/g" "$project_dir/scripts/release/start.cmd.template" > "$release_dir/$app/start.cmd"
    cp "$project_dir/scripts/release/background.sh.template" "$release_dir/$app/background.sh"
    chmod 700 "$release_dir/$app/start.sh" "$release_dir/$app/background.sh"
done

# 为本次发布生成凭证，不复用公开的测试私钥。
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$release_dir/server/certs/server.key" \
    -out "$release_dir/server/certs/server.crt" \
    -days 365 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
cp "$release_dir/server/certs/server.crt" "$release_dir/client/certs/server.crt"
secret=$(openssl rand -hex 32)
cat > "$release_dir/server/config/server.properties" <<CONFIG
bind=0.0.0.0
port=4433
usersFile=users.properties
tls.cert=../certs/server.crt
tls.key=../certs/server.key
connectTimeoutMillis=10000
idleTimeoutSeconds=300
maxStreams=1024
CONFIG
printf '%s\n' "$secret" | python3 "$project_dir/scripts/initialize-kernel.py" \
    --jar "$release_dir/client/client.jar" --db "$release_dir/client/kernel.db" \
    --ca "$release_dir/client/certs/server.crt" --username client1
printf '# 每行一个账号及其独立密码。修改后重启服务端。\nclient1=%s\n' "$secret" > "$release_dir/server/config/users.properties"
cp "$project_dir/scripts/release/README.md" "$release_dir/README.md"
mkdir -p "$release_dir/client/examples"
cp "$project_dir/examples/config-request.json" "$project_dir/examples/routing.json" "$release_dir/client/examples/"
sed 's|../examples/|examples/|g' "$project_dir/docs/web-api.md" > "$release_dir/client/WEB-API.md"
printf '\n未压缩的发布目录已生成：%s\n' "$release_dir"
