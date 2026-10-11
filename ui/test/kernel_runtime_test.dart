import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/services/proxy_controller.dart';

void main() {
  final java = Platform.environment['UI_TEST_JAVA'];
  final javac = Platform.environment['UI_TEST_JAVAC'];
  final jar = Platform.environment['UI_TEST_JAR'];
  test(
    '打包运行时的业务日志进入管理缓存和事件流，关闭后释放采集器',
    () async {
      final directory = await Directory.systemTemp.createTemp('network-logs-');
      try {
        final compile = await Process.run(javac!, [
          '--release',
          '25',
          '-cp',
          jar!,
          '-d',
          directory.path,
          'test/fixtures/KernelLogsProbe.java',
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}${compile.stderr}',
        );
        final result = await Process.run(java!, [
          ...kernelJvmArguments,
          '-cp',
          '${directory.path}${Platform.isWindows ? ';' : ':'}$jar',
          'KernelLogsProbe',
        ], workingDirectory: directory.path);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: java == null || javac == null || jar == null
        ? '指定 UI_TEST_JAVA、UI_TEST_JAVAC 和 UI_TEST_JAR 后验证实际运行时'
        : false,
  );
  test(
    '实际启动参数保证打包运行时持续序列化零版本号后仍输出有效数字',
    () async {
      final directory = await Directory.systemTemp.createTemp('network-jit-');
      try {
        final compile = await Process.run(javac!, [
          '--release',
          '25',
          '-cp',
          jar!,
          '-d',
          directory.path,
          'test/fixtures/KernelJsonProbe.java',
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}${compile.stderr}',
        );
        // 与实际启动使用同一组参数，分别启动三次以覆盖不同的编译时序。
        for (var i = 0; i < 3; i++) {
          final result = await Process.run(java!, [
            ...kernelJvmArguments,
            '-cp',
            '${directory.path}${Platform.isWindows ? ';' : ':'}$jar',
            'KernelJsonProbe',
          ], workingDirectory: directory.path);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip: java == null || javac == null || jar == null
        ? '指定 UI_TEST_JAVA、UI_TEST_JAVAC 和 UI_TEST_JAR 后验证实际运行时'
        : false,
  );
}
