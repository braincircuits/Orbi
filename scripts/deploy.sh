#!/usr/bin/env bash
# 读取简单 properties 配置，上传发布文件并依次执行远程命令。
set -Ee -o pipefail
umask 077
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_file="$project_dir/deploy.local.properties"
dry_run=false
log() { printf '[部署] %s\n' "$*"; }
fail() { log "错误：$*" >&2; exit 1; }
trap 'rc=$?; printf "[部署] 执行失败（退出码 %s），已停止。\n" "$rc" >&2; exit "$rc"' ERR
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || fail '--config 后必须提供配置文件路径'
            config_file=$2; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help)
            printf '%s\n' '用法：bash scripts/deploy.sh [--config 配置文件] [--dry-run]' \
                '默认读取项目根目录 deploy.local.properties；--dry-run 只预览，不连接服务器。'
            exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done

trim() {
    local text=$1
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}
# 使用普通 Shell 单引号，远程登录 Shell 不需要支持 Bash 的特殊引用语法。
quote() {
    local text=${1//\'/\'\\\'\'}
    printf "'%s'" "$text"
}
local_path() {
    case "$1" in
        '~/'*) printf '%s/%s' "$HOME" "${1:2}" ;;
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$project_dir" "$1" ;;
    esac
}

[ -f "$config_file" ] && [ -r "$config_file" ] || fail "配置不存在或不可读：$config_file"
host= user= port= identity= remote_dir= remote_name=
auth=key
local_file=release/server/server.jar
keys=() numbers=() commands=()
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line=$(trim "$line")
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == *=* ]] || fail "配置第 $line_number 行缺少 ="
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    for existing in "${keys[@]}"; do
        [ "$key" != "$existing" ] || fail "重复配置项：$key"
    done
    keys+=("$key")
    case "$key" in
        ssh.host) host=$value ;;
        ssh.auth) auth=$value ;;
        ssh.user) user=$value ;;
        ssh.port) port=$value ;;
        ssh.identityFile) identity=$value ;;
        local.file) local_file=$value ;;
        remote.dir) remote_dir=$value ;;
        remote.name) remote_name=$value ;;
        command.*)
            number=${key#command.}
            [[ "$number" =~ ^[1-9][0-9]*$ ]] && [ "${#number}" -le 9 ] ||
                fail "命令编号必须是 1 至 999999999 的整数，不带前导零：$key"
            [ -n "$value" ] || fail "$key 不能为空"
            # 每条命令必须语法完整，避免未闭合引号吞掉下一条命令。
            bash -n -c "$value" || fail "$key 的 Bash 语法无效"
            numbers+=("$number"); commands+=("$value") ;;
        *) fail "未知配置项：$key" ;;
    esac
done < "$config_file"

[[ "$host" =~ ^[a-zA-Z0-9_:][a-zA-Z0-9_.:%-]*$ ]] || fail 'ssh.host 必须是 SSH 别名、域名或 IP，不包含用户名'
case "$auth" in
    key|password) ;;
    *) fail 'ssh.auth 只能是 key 或 password' ;;
esac
if [ "$auth" = password ] && [ -n "$identity" ]; then
    fail '密码模式不使用私钥，请删除或清空 ssh.identityFile'
fi
if [ -n "$user" ]; then
    [[ "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || fail 'ssh.user 格式无效'
fi
if [ -n "$port" ]; then
    [[ "$port" =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] || fail 'ssh.port 必须是 1 至 65535 的整数'
    port=$((10#$port))
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail 'ssh.port 必须是 1 至 65535 的整数'
fi
[[ "$remote_dir" == /* ]] || fail 'remote.dir 必须是 Linux 绝对路径'
[ -n "$local_file" ] || fail 'local.file 不能为空'
local_file=$(local_path "$local_file")
[ -n "$remote_name" ] || remote_name=${local_file##*/}
case "$remote_name" in ''|.|..|*/*) fail 'remote.name 必须是文件名，不能包含目录' ;; esac
[ "${#commands[@]}" -gt 0 ] || fail '至少需要配置一条 command.N 命令'
# 数值排序，编号允许不连续；command.10 排在 command.2 后面。
for ((i=1; i<${#numbers[@]}; i++)); do
    number=${numbers[i]}; command_text=${commands[i]}; j=$i
    while ((j > 0)) && ((numbers[j-1] > number)); do
        numbers[j]=${numbers[j-1]}; commands[j]=${commands[j-1]}; j=$((j - 1))
    done
    numbers[j]=$number; commands[j]=$command_text
done

log "服务器：${user:-SSH 配置用户}@${host}（端口：${port:-沿用 SSH 配置}）"
if [ "$auth" = password ]; then
    log '认证方式：密码（实际部署时由 SSH 在本机终端提示输入，不回显、不保存）'
else
    log '认证方式：密钥（使用 SSH 配置或 Agent，不提示输入登录密码）'
fi
log "上传文件：$local_file"
log "目标文件：${remote_dir%/}/$remote_name"
if [ "$dry_run" = true ]; then
    for ((i=0; i<${#commands[@]}; i++)); do
        log "command.${numbers[i]}：${commands[i]}"
    done
    log '预览完成，未连接服务器。'
    exit 0
fi
command -v ssh >/dev/null || fail '未找到 ssh，请安装 OpenSSH 客户端'
[ -f "$local_file" ] && [ -r "$local_file" ] || fail "上传来源不存在或不可读：$local_file"
ssh_args=(-T -o StrictHostKeyChecking=yes -o ConnectTimeout=15
          -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
if [ "$auth" = password ]; then
    # 上传占用标准输入；SSH 从控制终端读取密码，不能改为从上传文件读取。
    (: <> /dev/tty) 2>/dev/null || fail '密码模式需要本机交互终端，请在终端中运行；无人值守部署请使用 ssh.auth=key'
    # 禁止复用已认证连接，确保本次执行按密码模式认证。
    ssh_args+=(-o BatchMode=no -o PreferredAuthentications=password
               -o PasswordAuthentication=yes -o PubkeyAuthentication=no
               -o KbdInteractiveAuthentication=no -o ControlPath=none)
else
    ssh_args+=(-o BatchMode=yes -o PreferredAuthentications=publickey)
fi
[ -z "$user" ] || ssh_args+=(-l "$user")
[ -z "$port" ] || ssh_args+=(-p "$port")
if [ -n "$identity" ]; then
    identity=$(local_path "$identity")
    [ -f "$identity" ] && [ -r "$identity" ] || fail "SSH 私钥不存在或不可读：$identity"
    ssh_args+=(-i "$identity")
fi
# macOS 自带 shasum，Linux 通常提供 sha256sum；摘要均从标准输入计算。
if command -v sha256sum >/dev/null; then
    digest=$(sha256sum < "$local_file")
elif command -v shasum >/dev/null; then
    digest=$(shasum -a 256 < "$local_file")
else
    fail '未找到 sha256sum 或 shasum'
fi
digest=${digest%% *}

remote_script=$(
    printf 'target_dir=%s\ntarget_name=%s\nexpected=%s\n' \
        "$(quote "$remote_dir")" "$(quote "$remote_name")" "$(quote "$digest")"
    cat <<'REMOTE'
set -Eeuo pipefail
umask 077
stage='准备远程目录'
upload=''
trap 'rc=$?; printf "[部署] 失败：%s（退出码 %s）\n" "$stage" "$rc" >&2; exit "$rc"' ERR
trap 'if [ -n "$upload" ]; then rm -f -- "$upload"; fi' EXIT
mkdir -p -- "$target_dir"
cd -- "$target_dir"
if [ -d "./$target_name" ]; then
    printf '%s\n' '[部署] 目标文件名已被目录占用' >&2
    exit 1
fi
stage='上传文件'
upload=$(mktemp "$PWD/.deploy-upload.XXXXXXXX")
printf '%s\n' '[部署] 正在接收文件……'
cat > "$upload"
stage='校验上传文件'
actual=$(sha256sum < "$upload")
[ "${actual%% *}" = "$expected" ]
stage='替换目标文件'
chmod 644 "$upload"
mv -fT -- "$upload" "./$target_name"
upload=''
printf '%s\n' '[部署] 文件校验通过，目标文件已更新。'
exec < /dev/null
REMOTE
    for ((i=0; i<${#commands[@]}; i++)); do
        printf "stage='执行 command.%s（第 %s/%s 条命令）'\n" "${numbers[i]}" "$((i + 1))" "${#commands[@]}"
        printf '%s\n' 'printf "[部署] %s\n" "$stage"' "${commands[i]}"
    done
    printf '%s\n' 'printf "%s\n" "[部署] 所有远程命令执行成功。"'
)
bash -n -c "$remote_script" || fail '生成的远程脚本语法检查失败'
log '连接服务器并上传；远程输出如下。'
if SSH_ASKPASS_REQUIRE=never ssh "${ssh_args[@]}" "$host" "bash -c $(quote "$remote_script")" < "$local_file"; then
    log '部署完成。'
else
    rc=$?
    fail "部署失败（SSH 退出码 ${rc}），已停止；目标文件可能已更新，请检查远程输出。"
fi
