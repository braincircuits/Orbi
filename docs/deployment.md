# 自动部署到 Linux

脚本把一个本地文件上传到指定目录，校验 SHA-256 后替换目标文件，再按顺序执行配置的命令。默认来源是 `release/server/server.jar`，不自动构建。

## 配置与执行

本机需要 Bash、OpenSSH 客户端和 `sha256sum` 或 `shasum`，不需要 Python 或 jq。Linux 需要 Bash、`sha256sum`、`mktemp` 及 GNU `mv` 等常用工具。支持密钥认证和执行时输入密码两种方式，默认使用密钥，不跳过主机身份校验。首次使用前，请正常通过 SSH 连接并核实服务器指纹。

在项目根目录执行：

```sh
cp examples/deploy.properties deploy.local.properties
```

修改 `deploy.local.properties` 中的服务器和目录，再预览并执行：

```sh
bash scripts/deploy.sh --dry-run
bash scripts/deploy.sh
```

本机配置已加入 Git 忽略规则。也可通过 `--config /路径/其他配置.properties` 指定配置。脚本可以从任意工作目录调用，`local.file` 和 `ssh.identityFile` 的相对路径始终以项目根目录为基准，支持 `~/`；远程路径必须是绝对路径。请使用 Bash 执行，不要用 `sh`。

完整配置示例：

```properties
ssh.host=my-server
ssh.auth=key
ssh.user=deploy
ssh.port=22
ssh.identityFile=~/.ssh/id_ed25519
local.file=release/server/server.jar
remote.dir=/opt/network/server
remote.name=server.jar
command.1=sh ./background.sh restart
command.2=sh ./background.sh status
```

| 配置项 | 含义 |
| --- | --- |
| `ssh.host` | 必填，SSH 别名、域名或 IP；IPv6 不加方括号 |
| `ssh.auth` | 可选，默认 `key`；填写 `password` 则在实际执行时输入密码，不可留空 |
| `ssh.user`、`ssh.port` | 可选；省略或留空时沿用 SSH 配置 |
| `ssh.identityFile` | 仅密钥模式可用；省略或留空时使用 SSH 配置和 Agent，密码模式须删除或留空 |
| `local.file` | 可选，默认 `release/server/server.jar`，不能留空 |
| `remote.dir` | 必填，Linux 绝对目录；不存在时创建，需要当前 SSH 用户有写权限 |
| `remote.name` | 可选，省略或留空时使用本地文件名，不能包含目录 |
| `command.N` | 至少一条非空 Bash 命令，按编号数值从小到大执行 |

配置文件使用 UTF-8，每行一个 `键=值`，仅在第一个 `=` 处分隔。忽略空行和以 `#` 开头的注释行，去掉键和值两端的空白；支持 LF、CRLF，以及末行没有换行符的文件。编号范围为 1 至 999999999，不带前导零，可不连续，`command.10` 在 `command.2` 之后。重复键、未知字段、无效编号和 Bash 语法错误会在连接服务器前报错。

值不加外层引号，路径可以包含空格；命令内部的引号、`=`、`#`、反斜杠原样保留。不支持行尾配置注释、续行、变量插值或 Java Properties 的 Unicode 转义。普通配置作为文本读取，不会在本机执行；只有 `command.N` 在远程作为 Bash 命令执行，每条命令必须语法完整。

示例中的 `background.sh`、`start.sh`、Java 运行环境、配置及证书须已在服务器上准备好；脚本只上传指定文件。使用 systemd 时，可把命令替换为 `sudo -n systemctl restart 实际服务名` 和 `systemctl is-active --quiet 实际服务名`。命令需要权限时，应预先配置相应权限；SSH 登录成功后的远程命令不提供交互终端，不支持再输入 sudo 密码。

## 两种 SSH 认证方式

密钥模式适合自动部署：

```properties
ssh.auth=key
# 可选；也可以沿用 ~/.ssh/config 和 SSH Agent
ssh.identityFile=~/.ssh/id_ed25519
```

使用非交互公钥认证，不提示输入登录密码或私钥口令。加密私钥需事先通过 `ssh-add` 加入 Agent；认证失败立即停止。

密码模式适合在本机终端手动部署：

```properties
ssh.auth=password
# 删除或清空 ssh.identityFile，不配置密码字段
```

执行 `bash scripts/deploy.sh` 时，由 OpenSSH 在本机控制终端提示输入登录密码，输入不回显。脚本不读取、保存或打印密码，不需要 sshpass；密码不会放入配置、命令参数或环境变量。文件上传使用标准输入，密码输入使用独立的控制终端，二者不会混用。

服务器必须允许 SSH 的 password 认证。此模式不尝试公钥或 keyboard-interactive 认证，也不复用已认证的 SSH 共享连接；无可用控制终端时，在连接前报错。`--dry-run` 会显示所选认证方式，不要求终端、不连接服务器、不提示输入密码。

## 执行与失败行为

- 先在目标目录创建临时文件，通过同一条 SSH 连接上传并校验；校验成功后，以文件重命名替换目标文件。文件权限设为 `0644`，所有者是 SSH 用户。配置、证书、数据库等其他文件保持不变。
- 命令从 `remote.dir` 开始，在同一个 Bash 中运行；前一条命令设置的变量、函数或 `cd` 会影响后一条。标准输入为空，标准输出和错误输出实时显示。
- Bash 开启 `set -Eeuo pipefail`。普通命令失败、管道中命令失败或引用未定义变量，均停止后续执行。Bash 的条件判断、`||` 等具有自身语义；不要使用 `|| true`、`set +e`、后台 `&` 等写法掩盖需要终止部署的失败。命令列表应使用前台命令，后台服务由进程管理脚本或 systemd 启动。
- 上传或校验失败时不替换原文件，正常退出时清理临时文件。文件替换后命令失败，不会恢复旧文件，也不会撤销已经执行的命令。日志会显示失败阶段，脚本返回非零退出码。
- 连接突然中断时，远程执行结果可能无法确认；检查文件和服务状态后再决定是否重试。不要对同一目标同时运行多个部署。
- `--dry-run` 检查配置及命令的 Bash 语法并显示文件、目标与排序后的命令，不连接服务器，也不验证远程环境、本地产物或私钥是否存在。预览会原样显示命令，请勿在命令中写入密码等敏感内容。

开发时可用 Python 3 运行本地回归检查，不会连接实际服务器；Python 只用于测试，不是部署依赖：

```sh
python3 -m unittest discover -s scripts/tests -p 'test_deploy.py'
```
