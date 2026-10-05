#!/bin/sh
set -eu
umask 077
config_dir=${1:-.local-h3}
if [ -e "$config_dir" ]; then
    echo "Refusing to overwrite existing directory: $config_dir" >&2
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
cat > "$config_dir/client.properties" <<CONFIG
bind=127.0.0.1
port=8080
server.host=127.0.0.1
server.port=4433
password=$secret
tls.ca=server.crt
tls.serverName=localhost
routesFile=pac.txt
CONFIG
printf '# Empty: route all destinations through HTTP/3.\n' > "$config_dir/pac.txt"
printf 'Local development configuration created in %s\n' "$config_dir"
