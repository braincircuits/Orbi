import 'dart:io';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/database_settings.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class WindowsBundleDesktop extends NativeBridge {
  WindowsBundleDesktop(this.directory, this.resources);
  final Directory directory;
  final String resources;

  @override
  Future<Map<String, String>> environment() async => {
    'support': directory.path,
    'resources': resources,
  };

  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final bundle = Platform.environment['UI_TEST_WINDOWS_BUNDLE'];
  for (final databasePath in ['kernel.db', '数据库/内核.db']) {
    test(
      'Windows 便携数据移动后可重启，证书随 $databasePath 保存和移动',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'orbi-portable-paths-',
        );
        var application = await Directory('${root.path}/原位置').create();
        final proxy = await Directory('${application.path}/proxy').create();
        for (final file in Directory('$bundle/proxy').listSync()) {
          if (file is File &&
              (file.path.endsWith('.dll') ||
                  file.path.endsWith('network-core.exe'))) {
            await file.copy('${proxy.path}/${file.uri.pathSegments.last}');
          }
        }
        final external = await File(
          '../ClientG/src/test/resources/tls/localhost.crt',
        ).copy('${root.path}/外部 CA.crt');
        ProxyController? controller;
        int? pid;
        try {
          for (var pass = 0; pass < 3; pass++) {
            final data = Directory('${application.path}/data');
            controller = ProxyController(directory: data);
            if (pass == 0) {
              await controller.databases.write(
                data,
                DatabaseSettings(path: databasePath),
              );
            }
            await controller.connect(ProxyProfile(), application.path);
            pid =
                (jsonDecode(await controller.endpointFile.readAsString())
                        as Map<String, dynamic>)['pid']
                    as int;
            final profile = pass == 0
                ? ProxyProfile(
                    values: {
                      'server.host': '127.0.0.1',
                      'password': 'portable-test',
                      'tls.ca': external.path,
                      'port': '0',
                    },
                    routingMode: 'direct',
                  )
                : controller.appliedProfile!;
            await controller.apply(profile, application.path);
            final ca = File(
              controller.appliedProfile!.selected.values['tls.ca']!,
            );
            expect(await ca.exists(), isTrue);
            expect(
              (await ca.resolveSymbolicLinks()).toLowerCase(),
              startsWith((await data.resolveSymbolicLinks()).toLowerCase()),
            );
            expect(
              Directory(
                '${File('${data.path}/$databasePath').parent.path}/certs',
              ).listSync().length,
              1,
            );
            await controller.shutdown();
            await Process.run('powershell.exe', [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'Wait-Process -Id $pid -Timeout 10 -ErrorAction SilentlyContinue',
            ]);
            controller.dispose();
            controller = null;
            pid = null;
            if (pass == 0) await external.delete();
            application = await application.rename('${root.path}/移动后-$pass');
          }
        } finally {
          if (controller != null) {
            await controller.shutdown();
            controller.dispose();
          }
          if (pid != null) {
            await Process.run('powershell.exe', [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'Wait-Process -Id $pid -Timeout 10 -ErrorAction SilentlyContinue',
            ]);
          }
          await root.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows || bundle == null,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
  test(
    'Windows 应用包自动启动内置内核，支持空连接直连模式与完整退出',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orbi-windows-bundle-',
      );
      final model = ProxyViewModel(
        native: WindowsBundleDesktop(directory, bundle!),
      );
      int? kernelPid;
      try {
        await model.initialize();
        kernelPid =
            (jsonDecode(await model.proxy.endpointFile.readAsString())
                    as Map<String, dynamic>)['pid']
                as int;
        expect(model.usesBundledKernel, isTrue);
        expect(
          model.usesNativeKernel,
          File('$bundle/proxy/network-core.exe').existsSync(),
        );
        expect(model.proxy.connected, isTrue);
        expect(model.proxy.capabilities, contains('windowsTun'));
        expect(model.java.text, isEmpty);
        expect(model.jar.text, isEmpty);
        await model.setRoutingMode('direct');
        model.fields['port']!.text = '0';
        model.changed('');
        await model.apply();
        await model.start();
        expect(model.proxy.running, isTrue);
        expect(model.proxy.appliedProfile!.connections, isEmpty);
        expect(await model.prepareToExit(), isTrue);
        expect(await model.proxy.endpointFile.exists(), isFalse);
      } finally {
        await model.proxy.shutdown();
        model.dispose();
        // 发现文件移除后 JVM 还会释放日志和当前目录句柄，Windows 必须等进程实际结束再删除临时目录。
        if (kernelPid != null) {
          await Process.run('powershell.exe', [
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Wait-Process -Id $kernelPid -Timeout 10 -ErrorAction SilentlyContinue',
          ]);
        }
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || bundle == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
