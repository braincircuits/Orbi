import 'package:network_ui/services/kernel_api_client.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/runtime_preferences.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class IntegrationDesktop extends NativeBridge {
  IntegrationDesktop(this.directory);
  final Directory directory;
  @override
  Future<Map<String, String>> environment() async => {
    'support': directory.path,
    'resources': directory.path,
  };
  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('等待内核事件超时');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final jar = Platform.environment['UI_TEST_JAR'];
  final java = Platform.environment['UI_TEST_JAVA'];
  test(
    '真实 UI 路由切换：保存精确目标规则，保留文件来源和密码，草稿应用不会丢失规则',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-target-ui-',
      );
      final rulesFile = File('${directory.path}/routes.txt');
      await rulesFile.writeAsString('example.com\n');
      await RuntimePreferences().write(directory, RuntimePaths(java!, jar!));
      final seed = ProxyController(directory: directory);
      final model = ProxyViewModel(native: IntegrationDesktop(directory));
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      try {
        await seed.start(
          ProxyProfile(
            values: {
              'protocol': 'http2',
              'server.host': '127.0.0.1',
              'port': '0',
              'password': 'target-test-password',
            },
            routesFile: rulesFile.path,
            inlineRules: false,
            javaPath: java,
            jarPath: jar,
          ),
          '',
        );

        await model.initialize();
        await model.routeTarget('WWW.Example.COM.:443', 'proxy');
        expect(model.proxy.appliedProfile!.targetRoutes, {
          'www.example.com': 'proxy',
        });

        expect(model.inlineRules, isFalse);
        expect(model.rules.text, isEmpty);
        expect(model.routesFile.text, rulesFile.path);
        model.connectionName.text = '路由切换后的名称';
        model.changed('');
        final revision = model.proxy.revision;
        await model.routeTarget('www.example.com:443', 'direct');
        expect(model.proxy.revision, greaterThan(revision));
        expect(model.dirty, isTrue);
        expect(model.connectionName.text, '路由切换后的名称');
        expect(messages.last.text, contains('编辑草稿已保留'));
        final routeSaved = jsonDecode(
          await File(model.proxy.configPath).readAsString(),
        ) as Map<String, dynamic>;
        expect(
          ((routeSaved['connections'] as List).first as Map)['name'],
          isNot('路由切换后的名称'),
        );
        await model.apply();
        expect(model.proxy.appliedProfile!.targetRoutes, {
          'www.example.com': 'direct',
        });
        final saved = jsonDecode(
          await File(model.proxy.configPath).readAsString(),
        ) as Map<String, dynamic>;
        expect((saved['local'] as Map)['routesFile'], rulesFile.path);
        expect((saved['local'] as Map).containsKey('routesInline'), isFalse);
        expect(
          ((saved['connections'] as List).first as Map)['config']['password'],
          'target-test-password',
        );
        await model.routeTarget('[2001:db8::1]:443', 'direct');
        expect(
          model.proxy.appliedProfile!.targetRoutes.values,
          contains('direct'),
        );
        await model.routeTarget('www.example.com:80', 'auto');
        expect(
          model.proxy.appliedProfile!.targetRoutes.containsKey(
            'www.example.com',
          ),
          isFalse,
        );
        expect(await rulesFile.readAsString(), 'example.com\n');
      } finally {
        await subscription.cancel();
        await model.proxy.shutdown();
        model.dispose();
        seed.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: jar == null || java == null,
  );
  test(
    '真实内核：客户端启动按保存配置自动开启代理，接管和重新显示不重启',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-startup-ui-',
      );
      await RuntimePreferences().write(directory, RuntimePaths(java!, jar!));
      final seed = ProxyController(directory: directory);
      final model = ProxyViewModel(native: IntegrationDesktop(directory));
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      final profile = ProxyProfile(
        values: {
          'protocol': 'http2',
          'server.host': '127.0.0.1',
          'port': '0',
          'password': 'startup-test-password',
        },
        rules: '127.0.0.1',
        jarPath: jar,
        javaPath: java,
      );
      try {
        await seed.start(profile, '');

        final revision = seed.revision;
        await seed.shutdown();
        await model.initialize();
        expect(model.proxy.running, isTrue);
        expect(model.proxy.revision, revision);

        final address = model.proxy.address;
        final reattached = ProxyViewModel(
          native: IntegrationDesktop(directory),
        );
        try {
          await reattached.initialize();
          expect(reattached.proxy.address, address);
          await model.stop();
          await model.initialize();
          await model.reload();
          expect(model.proxy.running, isFalse);
          expect(messages.where((item) => item.failure), isEmpty);
        } finally {
          reattached.dispose();
        }
      } finally {
        await subscription.cancel();
        await model.proxy.shutdown();
        model.dispose();
        seed.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: jar == null || java == null
        ? '指定 UI_TEST_JAR 和 UI_TEST_JAVA 后验证启动时自动开启代理'
        : false,
  );
  test(
    '真实内核：隧道明细通过快照和 SSE 到达 UI，关闭连接后移除',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-tunnels-',
      );
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final targets = <Socket>[];
      origin.listen((socket) {
        targets.add(socket);
        socket.listen((data) => socket.add(data), onDone: socket.destroy);
      });
      final controller = ProxyController(directory: directory);
      final other = ProxyController(directory: directory);
      Socket? browser;
      final profile = ProxyProfile(
        values: {
          'protocol': 'http2',
          'server.host': '127.0.0.1',
          'port': '0',
          'password': 'tunnel-test-secret',
        },
        rules: '127.0.0.1',
        jarPath: jar!,
        javaPath: java!,
      );
      try {
        await controller.start(profile, '');
        await until(() => controller.streaming);
        final port = int.parse(controller.address.split(':').last);
        browser = await Socket.connect('127.0.0.1', port);
        final headers = StringBuffer();
        final connected = Completer<void>();
        browser.listen((data) {
          headers.write(ascii.decode(data));
          if (headers.toString().contains('\r\n\r\n') &&
              !connected.isCompleted) {
            connected.complete();
          }
        });
        browser.write(
          'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\nHost: localhost\r\n\r\n',
        );
        await browser.flush();
        await connected.future.timeout(const Duration(seconds: 5));
        expect(headers.toString(), startsWith('HTTP/1.1 200'));
        await until(() => controller.tunnels.length == 1);
        expect(controller.tunnels.single.target, '127.0.0.1:${origin.port}');
        expect(controller.tunnels.single.route, 'direct');
        expect(controller.tunnels.single.state, 'active');
        await other.connect(profile, '', launch: false);
        expect(other.tunnels.single.id, controller.tunnels.single.id);
        browser.destroy();
        await until(() => controller.tunnels.isEmpty && other.tunnels.isEmpty);
        await controller.stop();
        expect(controller.tunnels, isEmpty);
      } finally {
        browser?.destroy();
        for (final socket in targets) {
          socket.destroy();
        }
        await origin.close();
        other.dispose();
        await controller.shutdown();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: jar == null || java == null
        ? '指定 UI_TEST_JAR 和 UI_TEST_JAVA 后验证真实隧道列表推送'
        : false,
  );
  test(
    '真实 UI 操作：应用即保存，外部配置自动同步，内核重启后使用保存配置',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-apply-save-',
      );
      await RuntimePreferences().write(directory, RuntimePaths(java!, jar!));
      final model = ProxyViewModel(native: IntegrationDesktop(directory));
      final other = ProxyController(directory: directory);
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      try {
        await model.initialize();
        expect(model.connectionDrafts, isEmpty);
        model.addConnection();
        model.fields['protocol']!.text = 'http2';
        model.fields['server.host']!.text = '127.0.0.1';
        model.fields['port']!.text = '0';
        model.fields['password']!.text = 'apply-save-test-password';
        model.changed('');
        await model.apply();
        expect(messages.where((message) => message.failure), isEmpty);

        final saved = jsonDecode(
          await File(model.proxy.configPath).readAsString(),
        ) as Map;
        expect(
          saved['connections'][0]['config']['password'],
          'apply-save-test-password',
        );
        await other.connect(model.draftProfile(), '', launch: false);
        model.connectionName.text = '尚未应用的名称';
        model.changed('');
        final external = other.appliedProfile!;
        external.selected.name = '内核最新名称';
        await other.apply(external, '');
        await until(() => model.connectionName.text == '内核最新名称');
        expect(model.dirty, isFalse);
        expect(model.baseRevision, other.configurationRevision);
        model.connectionName.text = '已保存的新名称';
        model.changed('');
        await model.apply();

        await model.shutdown();
        await model.reload();
        expect(model.connectionName.text, '已保存的新名称');
        expect(model.proxy.configurationChanged, isFalse);
        expect(model.dirty, isFalse);
        expect(messages.where((message) => message.failure), isEmpty);
        expect(await model.prepareToExit(), isTrue);
        expect(await model.proxy.endpointFile.exists(), isFalse);
        expect(model.proxy.canShutdown, isFalse);
      } finally {
        await subscription.cancel();
        other.dispose();
        await model.proxy.shutdown();
        model.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip: jar == null || java == null
        ? '指定 UI_TEST_JAR 和 UI_TEST_JAVA 后验证应用保存和内核配置同步'
        : false,
  );
  test(
    '真实 Web 内核：连接失败日志通过 SSE 到达客户端，重新连接补齐历史',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-log-ui-',
      );
      final unavailable = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final serverPort = unavailable.port;
      await unavailable.close();
      var controller = ProxyController(directory: directory);
      final profile = ProxyProfile(
        values: {
          'protocol': 'http2',
          'server.host': '127.0.0.1',
          'server.port': '$serverPort',
          'port': '0',
          'password': 'log-test-password',
          'connectTimeoutMillis': '500',
        },
        jarPath: jar!,
        javaPath: java!,
      );
      final http = HttpClient();
      try {
        await controller.start(profile, '');
        await until(() => controller.streaming);
        http.findProxy = (_) => 'PROXY ${controller.address}';
        final response = await (await http.getUrl(
          Uri.parse('http://example.test/'),
        )).close();
        expect(response.statusCode, 502);
        await response.drain<void>();
        await until(
          () => controller.logs.any(
            (entry) =>
                entry.level == 'WARN' && entry.message.contains('代理连接失败'),
          ),
        );
        controller.dispose();
        controller = ProxyController(directory: directory);
        await controller.connect(profile, '', launch: false);
        await until(
          () => controller.logs.any(
            (entry) =>
                entry.level == 'WARN' && entry.message.contains('代理连接失败'),
          ),
        );
        expect(
          controller.logs.join('\n'),
          isNot(contains('log-test-password')),
        );
      } finally {
        http.close(force: true);
        await controller.shutdown();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: jar == null || java == null
        ? '指定 UI_TEST_JAR 和 UI_TEST_JAVA 后执行真实内核日志联调'
        : false,
  );
  test(
    '真实 Web 内核：热更新、版本冲突、密码保留、持久化、诊断与脱离 UI 生命周期',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-web-test-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.write('flutter-web-ok');
        await request.response.close();
      });
      var controller = ProxyController(directory: directory);
      ProxyController? other;
      final profile = ProxyProfile(
        values: {
          'server.host': '127.0.0.1',
          'port': '0',
          'password': 'test-password',
        },
        rules: '127.0.0.1',
        jarPath: jar!,
        javaPath: java!,
      );
      Future<void> request() async {
        final http = HttpClient()
          ..findProxy = (_) => 'PROXY ${controller.address}';
        try {
          final response = await (await http.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/'),
          )).close();
          expect(response.statusCode, 200);
          expect(await utf8.decoder.bind(response).join(), 'flutter-web-ok');
        } finally {
          http.close(force: true);
        }
      }

      try {
        await controller.start(profile, '');
        await until(() => controller.streaming);
        expect(controller.running, isTrue);

        await request();
        final rulesGeneration = controller.networkGeneration;
        await controller.setRoutingMode('direct');
        expect(controller.routingMode, 'direct');
        expect(controller.networkGeneration, greaterThan(rulesGeneration));
        await request();
        await expectLater(
          controller.startOverview('latency'),
          throwsA(isA<KernelApiException>()),
        );
        await controller.setRoutingMode('proxy');
        expect(controller.appliedProfile!.routingMode, 'proxy');
        await controller.diagnose('127.0.0.1:443');
        await until(
          () => controller.operations.values.any((job) => job.finished),
        );
        expect(controller.operations.values.last.result.action, 'proxy');
        await controller.setRoutingMode('rules');
        await request();
        expect(controller.appliedProfile!.selected.hasPassword, isTrue);
        expect(controller.appliedProfile!.selected.values['password'], isEmpty);

        final saved =
            jsonDecode(await File(controller.configPath).readAsString()) as Map;
        expect(saved['connections'][0]['config']['password'], 'test-password');
        expect((await File(controller.configPath).stat()).mode & 0x1ff, 0x180);
        expect((await controller.endpointFile.stat()).mode & 0x1ff, 0x180);
        other = ProxyController(directory: directory);
        await other.connect(profile, '', launch: false);
        final staleRevision = other.configurationRevision;
        final stale = other.appliedProfile!;
        final renamed = controller.appliedProfile!;
        renamed.selected.name = '热更新后的名称';
        await controller.apply(renamed, '');
        stale.selected.name = '不应覆盖的旧草稿';
        await expectLater(
          other.apply(stale, '', expectedRevision: staleRevision),
          throwsA(
            isA<KernelApiException>().having(
              (e) => e.code,
              '错误代码',
              'REVISION_CONFLICT',
            ),
          ),
        );
        expect(stale.selected.name, '不应覆盖的旧草稿');
        await controller.refreshConfiguration();
        expect(controller.appliedProfile!.selected.name, '热更新后的名称');
        expect(controller.appliedProfile!.selected.hasPassword, isTrue);
        await request();
        // 文件规则与内联规则切换热更新，既有监听保持可用。
        final ruleFile = File('${directory.path}/direct.txt');
        await ruleFile.writeAsString('127.0.0.1');
        final fileRules = controller.appliedProfile!;
        fileRules.inlineRules = false;
        fileRules.routesFile = ruleFile.path;
        await controller.apply(fileRules, '');
        await request();
        await ruleFile.writeAsString('127.0.0.1\nlocalhost');
        await controller.reloadRules();
        await controller.diagnose('localhost:443');
        await until(() => controller.operations.values.last.finished);
        expect(controller.operations.values.last.result.action, 'direct');
        // 监听失败不得推进版本，也不应悄悄停止原代理。
        final beforeFailure = controller.configurationRevision;
        final rejected = ProxyProfile.fromKernel(
          controller.appliedProfile!.runtimeConfiguration,
        );
        rejected.connections.first.hasPassword = true;
        rejected.values['port'] = '${origin.port}';
        await expectLater(
          controller.apply(rejected, ''),
          throwsA(isA<KernelApiException>()),
        );
        await controller.refreshConfiguration();
        expect(controller.configurationRevision, beforeFailure);
        expect(controller.running, isTrue);
        await request();

        final endpointBefore =
            jsonDecode(await controller.endpointFile.readAsString()) as Map;
        other.dispose();
        other = null;
        controller.dispose();
        controller = ProxyController(directory: directory);
        await controller.connect(profile, '', launch: false);
        expect(controller.running, isTrue);
        final endpointAfter =
            jsonDecode(await controller.endpointFile.readAsString()) as Map;
        expect(endpointAfter['pid'], endpointBefore['pid']);
        await request();
        await controller.stop();
        expect(controller.running, isFalse);
        expect(controller.connected, isTrue);
        await controller.start(
          controller.appliedProfile!,
          '',
          applyDraft: false,
        );
        await request();
        await controller.shutdown();
        expect(controller.running, isFalse);
        expect(await controller.endpointFile.exists(), isFalse);
        await controller.connect(profile, '');
        expect(controller.running, isFalse);
        expect(controller.appliedProfile!.selected.name, '热更新后的名称');
        await controller.stop();
        final empty = ProxyProfile(
          values: {'port': '0'},
          connections: [],
          defaultConnectionId: '',
        );
        expect(controller.configurationChanged, isFalse);
        await controller.apply(empty, '');

        expect(controller.appliedProfile!.connections, isEmpty);
        await controller.setRoutingMode('direct');
        await controller.start(
          controller.appliedProfile!,
          '',
          applyDraft: false,
        );
        expect(controller.running, isTrue);
        await request();
        await controller.stop();
        await expectLater(
          controller.startOverview('exit-ip'),
          throwsStateError,
        );
        expect(controller.logs.join('\n'), isNot(contains('test-password')));
      } finally {
        other?.dispose();
        await controller.shutdown();
        controller.dispose();
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip: jar == null || java == null
        ? '指定 UI_TEST_JAR 和 UI_TEST_JAVA 后执行真实内核联调'
        : false,
  );
}
