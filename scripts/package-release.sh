#!/bin/sh
# 构建不压缩的发布目录，客户端与服务端分别存放。
set -eu
umask 077
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
if [ -e "$release_dir" ]; then
    echo "拒绝覆盖已有发布目录：$release_dir" >&2
    exit 1
fi
command -v openssl >/dev/null
(cd "$project_dir" && mvn -B -ntp package)
mkdir -p "$release_dir"
release_dir=$(CDPATH= cd -- "$release_dir" && pwd)
for app in server client; do
    mkdir -p "$release_dir/$app/config" "$release_dir/$app/certs"
    sed "s/@APP@/$app/g" "$project_dir/scripts/release/start.sh.template" > "$release_dir/$app/start.sh"
    sed "s/@APP@/$app/g" "$project_dir/scripts/release/start.cmd.template" > "$release_dir/$app/start.cmd"
    cp "$project_dir/scripts/release/background.sh.template" "$release_dir/$app/background.sh"
    chmod 700 "$release_dir/$app/start.sh" "$release_dir/$app/background.sh"
done
cp "$project_dir/Server/target/Server-1.0-SNAPSHOT.jar" "$release_dir/server/server.jar"
cp "$project_dir/ClientG/target/clientG-1.0-SNAPSHOT.jar" "$release_dir/client/client.jar"

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
maxStreams=256
CONFIG
cat > "$release_dir/client/config/client.properties" <<CONFIG
bind=127.0.0.1
port=8080
server.host=127.0.0.1
server.port=4433
username=client1
password=$secret
tls.ca=../certs/server.crt
tls.serverName=localhost
routesFile=pac.txt
connectTimeoutMillis=10000
idleTimeoutSeconds=300
maxStreams=256
CONFIG
printf '# 每行一个账号及其独立密码。修改后重启服务端。\nclient1=%s\n' "$secret" > "$release_dir/server/config/users.properties"
printf '# 每行填写一个直连域名、IP 或 CIDR 网段；为空时全部走代理。\n' > "$release_dir/client/config/pac.txt"
cp "$project_dir/scripts/release/README.md" "$release_dir/README.md"
printf '\n未压缩的发布目录已生成：%s\n' "$release_dir"
