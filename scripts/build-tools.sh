#!/bin/sh
# 供构建入口加载本机工具配置；只解析已知字段，不把配置当作 Shell 执行。
build_tools_error() {
    printf '构建配置错误：%s\n' "$*" >&2
    return 1
}

build_tools_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

build_tools_path() {
    case "$1" in
        '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$build_tools_root" "$1" ;;
    esac
}

load_build_tools() {
    build_tools_root=$(CDPATH= cd -- "$1" && pwd) || return 1
    build_tools_file="$build_tools_root/build.local.properties"
    build_tools_java= build_tools_maven= build_tools_go= build_tools_flutter= build_tools_graalvm= build_tools_cc= build_tools_wintun=
    build_tools_seen='|'
    if [ -e "$build_tools_file" ]; then
        [ -f "$build_tools_file" ] && [ -r "$build_tools_file" ] || {
            build_tools_error "文件不可读：$build_tools_file"; return 1;
        }
        while IFS= read -r build_tools_line || [ -n "$build_tools_line" ]; do
            build_tools_line=$(build_tools_trim "$build_tools_line")
            case "$build_tools_line" in ''|\#*) continue ;; esac
            case "$build_tools_line" in
                *=*) ;;
                *) build_tools_error '每个配置项必须使用 键=值 格式'; return 1 ;;
            esac
            build_tools_key=$(build_tools_trim "${build_tools_line%%=*}")
            build_tools_value=$(build_tools_trim "${build_tools_line#*=}")
            case "$build_tools_key" in
                java.home|maven.bin|go.bin|flutter.bin|graalvm.home|cc.bin|wintun.home) ;;
                *) build_tools_error "未知配置项：$build_tools_key"; return 1 ;;
            esac
            case "$build_tools_seen" in
                *"|$build_tools_key|"*) build_tools_error "重复配置项：$build_tools_key"; return 1 ;;
            esac
            build_tools_seen="$build_tools_seen$build_tools_key|"
            # 可选字段留空表示使用环境变量或工具的默认查找方式。
            [ -n "$build_tools_value" ] || continue
            build_tools_value=$(build_tools_path "$build_tools_value")
            case "$build_tools_key" in
                java.home) build_tools_java=$build_tools_value ;;
                maven.bin) build_tools_maven=$build_tools_value ;;
                go.bin) build_tools_go=$build_tools_value ;;
                flutter.bin) build_tools_flutter=$build_tools_value ;;
                graalvm.home) build_tools_graalvm=$build_tools_value ;;
                cc.bin) build_tools_cc=$build_tools_value ;;
                wintun.home) build_tools_wintun=$build_tools_value ;;
            esac
        done < "$build_tools_file"
    fi
    JDK_HOME=${JDK_HOME:-${JAVA_HOME:-$build_tools_java}}
    MVN=${MVN:-${build_tools_maven:-mvn}}
    GO=${GO:-${build_tools_go:-go}}
    FLUTTER=${FLUTTER:-${build_tools_flutter:-flutter}}
    GRAALVM_HOME=${GRAALVM_HOME:-${build_tools_graalvm:-$JDK_HOME}}
    CC=${CC:-$build_tools_cc}
    WINTUN_HOME=${WINTUN_HOME:-$build_tools_wintun}
    export JDK_HOME MVN GO FLUTTER GRAALVM_HOME CC WINTUN_HOME
    if [ -n "$JDK_HOME" ]; then
        JAVA_HOME=$JDK_HOME
        PATH="$JAVA_HOME/bin:$PATH"
        export JAVA_HOME PATH
    fi
}
