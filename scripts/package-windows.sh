#!/bin/sh
# Windows 应用包默认使用 JAR；显式 --native 时构建并打包 AOT 内核。
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_ROOT/scripts/build-tools.sh"
load_build_tools "$PROJECT_ROOT"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) printf '%s\n' '请在 Windows 的 Git Bash 中运行此入口。' >&2; exit 1 ;; esac
exec python3 "$PROJECT_ROOT/scripts/package-windows.py" "$@"
