#!/bin/sh
# 只提交已暂存内容，统一身份与签名要求，不暂存文件、不推送。
set -eu

usage() {
    echo '用法：sh scripts/commit.sh -m "中文标题" [-m "中文正文" ...]' >&2
    echo '或：  sh scripts/commit.sh -F 提交备注文件' >&2
    exit 2
}

validate_messages() {
    [ "$#" -gt 0 ] || usage
    while [ "$#" -gt 0 ]; do
        [ "$1" = '-m' ] && [ "$#" -ge 2 ] || usage
        case "$2" in
            *[![:space:]]*) ;;
            *) echo '提交备注不能为空。' >&2; exit 2 ;;
        esac
        shift 2
    done
}

[ "$#" -gt 0 ] || usage
if [ "$1" = '-F' ]; then
    [ "$#" -eq 2 ] || usage
    [ -f "$2" ] && [ -r "$2" ] && [ -s "$2" ] || {
        echo '提交备注文件不存在、不可读或为空。' >&2; exit 2;
    }
    # git -C 会改变 Git 的工作目录，预先固定备注文件路径。
    case "$2" in
        /*) ;;
        *) set -- -F "$PWD/$2" ;;
    esac
else
    validate_messages "$@"
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# 统一 Git for Windows 的盘符路径与 Git Bash 路径，同时解析目录符号链接。
repo_path=$(git -C "$project_dir" rev-parse --show-toplevel)
repo_dir=$(CDPATH= cd -- "$repo_path" && pwd -P)
[ "$repo_dir" = "$project_dir" ] || {
    echo '脚本必须位于项目 Git 仓库的 scripts 目录中。' >&2; exit 1;
}

# 不把 Git 检查失败误判为没有改动。
if git -C "$repo_dir" diff --cached --quiet --exit-code; then
    echo '暂存区没有改动，请先核对并暂存本次提交的文件。' >&2
    exit 1
else
    result=$?
    [ "$result" -eq 1 ] || exit "$result"
fi
git -C "$repo_dir" diff --cached --check

# 沿用当前 Git 配置和环境中的邮箱，不修改任何身份配置。
author_email=$(git -C "$repo_dir" var GIT_AUTHOR_IDENT | sed -n 's/^.*<\(.*\)> .*$/\1/p')
committer_email=$(git -C "$repo_dir" var GIT_COMMITTER_IDENT | sed -n 's/^.*<\(.*\)> .*$/\1/p')
[ -n "$author_email" ] && [ -n "$committer_email" ] || {
    echo '无法确定 Git 作者或提交者邮箱。' >&2; exit 1;
}

if ! GIT_AUTHOR_NAME=codex6 GIT_COMMITTER_NAME=codex6 git -C "$repo_dir" commit -S "$@"; then
    echo '签名提交失败，未尝试无签名提交。请检查 Git 输出及仓库状态。' >&2
    exit 1
fi

commit=$(git -C "$repo_dir" rev-parse HEAD)
if ! git -C "$repo_dir" verify-commit HEAD; then
    echo "提交已创建，但签名验证失败：${commit}。不要直接重复提交或推送。" >&2
    exit 1
fi
if [ "$(git -C "$repo_dir" show -s --format=%an HEAD)" != 'codex6' ] ||
   [ "$(git -C "$repo_dir" show -s --format=%cn HEAD)" != 'codex6' ] ||
   [ "$(git -C "$repo_dir" show -s --format=%ae HEAD)" != "$author_email" ] ||
   [ "$(git -C "$repo_dir" show -s --format=%ce HEAD)" != "$committer_email" ]; then
    echo "提交已创建，但身份核对失败：${commit}。不要直接重复提交或推送。" >&2
    exit 1
fi
printf '签名及身份验证通过：%s\n' "$commit"
printf '作者和提交者均为 codex6，邮箱沿用原配置。未执行推送。\n'
