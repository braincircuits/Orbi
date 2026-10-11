#!/bin/sh
# 使用独立界面验证原生鼠标事件，不读取用户配置或启动代理内核。
set -eu
UI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FLUTTER=${FLUTTER:-flutter}
cd "$UI_ROOT"
restore_entrypoint() {
  printf '%s\n' '正在恢复正式应用入口…'
  "$FLUTTER" build macos --debug --config-only -t lib/main.dart
}
trap restore_entrypoint EXIT
printf '%s\n' '正在准备侧栏原生交互测试…'
"$FLUTTER" build macos --debug --config-only -t test/fixtures/sidebar_host.dart
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/macos-sidebar-tests -parallel-testing-enabled NO \
  FLUTTER_TARGET=test/fixtures/sidebar_host.dart
printf '%s\n' '侧栏、正文按钮和设置的原生鼠标交互测试通过。'
