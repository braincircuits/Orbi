import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'core_integration_test.dart' show IntegrationDesktop, until;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['NATIVE_CORE'];
  test(
    '应用包原生内核自动启动，不调用 Java，UI 退出后可重新接管',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-native-ui-',
      );
      final assets = Directory('${directory.path}/proxy');
      await assets.create();
      final bundled = File(
        '${assets.path}/network-core${Platform.isWindows ? '.exe' : ''}',
      );
      await File(executable!).copy(bundled.path);
      for (final file in Directory(File(executable).parent.path).listSync()) {
        if (file is File && file.path.endsWith('.dylib')) {
          await file.copy('${assets.path}/${file.uri.pathSegments.last}');
        }
      }
      if (!Platform.isWindows) {
        expect((await Process.run('chmod', ['+x', bundled.path])).exitCode, 0);
      }
      // 无效开发路径文件用于证明原生应用不读取 JVM 启动设置。
      await File('${directory.path}/ui.json').writeAsString('不是 JSON');
      final portReservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final unavailablePort = portReservation.port;
      await portReservation.close();
      final config = ProxyProfile(
        values: {
          'protocol': 'http2',
          'server.host': '127.0.0.1',
          'server.port': '$unavailablePort',
          'port': '0',
          'password': 'native-test-only',
        },
      );
      await File('${directory.path}/kernel.json')
          .writeAsString(jsonEncode(config.runtimeConfiguration));
      final model = ProxyViewModel(native: IntegrationDesktop(directory));
      final next = ProxyController(directory: directory);
      try {
        await model.initialize();
        expect(model.usesNativeKernel, isTrue);
        expect(model.java.text, isEmpty);
        expect(model.jar.text, isEmpty);
        expect(model.proxy.connected, isTrue);
        expect(model.proxy.running, isTrue);
        expect(model.proxy.appliedProfile!.values['port'], '0');
        // 使用不可用的本地服务端验证原生检测失败分支，不访问公共网络。
        await model.setRoutingMode('proxy');
        await model.proxy.startOverview('websites');
        await until(
          () => model.proxy.overviewOperation('websites')?.finished == true,
        );
        final websites = model.proxy
            .overviewOperation('websites')!
            .result
            .websites;
        expect(websites, hasLength(3));
        expect(websites.every((site) => site.state == 'failed'), isTrue);
        await model.proxy.startOverview('exit-ip');
        await until(
          () => model.proxy.overviewOperation('exit-ip')?.finished == true,
        );
        expect(model.proxy.overviewOperation('exit-ip')!.state, 'failed');
        await model.setRoutingMode('direct');
        expect(model.proxy.overviewOperation('websites'), isNull);
        expect(model.proxy.overviewOperation('exit-ip'), isNull);
        model.connectionName.text = '原生内核连接';
        model.changed('');
        await model.apply();
        expect(model.dirty, isFalse);

        final endpoint = await File('${directory.path}/run/control.json')
            .readAsString();
        model.dispose();
        await next.connect(ProxyProfile(), directory.path);
        expect(next.running, isTrue);
        expect(next.appliedProfile!.connections.single.name, '原生内核连接');
        expect(
          await File('${directory.path}/run/control.json').readAsString(),
          endpoint,
        );
      } finally {
        await next.shutdown();
        if (model.active) {
          await model.proxy.shutdown();
          model.dispose();
        }
        next.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: executable == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
