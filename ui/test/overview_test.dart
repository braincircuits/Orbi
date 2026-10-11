import 'traffic_fixture.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/kernel_api_client.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/overview_page.dart';
import 'package:network_ui/ui/proxy_home.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop;

class ReadyOverviewModel extends ProxyViewModel {
  ReadyOverviewModel(ProxyController proxy, Directory directory)
    : super(proxy: proxy, native: TestDesktop(directory)) {
    loading = false;
    accept(proxy.appliedProfile!);
  }
  @override
  Future<void> initialize() async {}
}

class OverviewApi extends KernelApiClient {
  int revision = 1, generation = 1, sequence = 0;
  String mode = 'proxy';
  String provider = '测试网络';
  bool running = true, failWrite = false;
  Completer<Map<String, dynamic>>? delayed;
  final calls = <String>[];
  Map<String, Object> get configuration => ProxyProfile(
    values: {'server.host': 'proxy.example', 'password': '测试密码'},
    routingMode: mode,
  ).runtimeConfiguration;

  @override
  Future<Map<String, dynamic>> request(
    Uri base,
    String token,
    String method,
    String path, {
    Object? body,
    int? expectedRevision,
  }) async {
    calls.add('$method $path');
    Object data = {};
    if (path == 'info') {
      data = {
        'apiVersion': 1,
        'capabilities': [
          'events',
          'hotSettings',
          'hotRoutes',
          'hotProfiles',
          'tunnels',
          'targetRoutes',
          'routingMode',
          'overviewTests',
          'traffic',
          'persistentHistory',
        ],
      };
    } else if (path == 'traffic') {
      data = trafficFixture();
    } else if (path == 'config') {
      data = configuration;
    } else if (path == 'status') {
      data = {
        'running': running,
        'traffic': trafficFixture(),
        'historyStorage': {
          'pendingRecords': 0,
          'droppedRecords': 0,
          'error': '',
        },
        'routingMode': mode,
        'networkGeneration': generation,
        'defaultConnectionId': 'default',
        'address': '127.0.0.1:8080',
      };
    } else if (path == 'routing/mode') {
      expect(expectedRevision, revision);
      if (failWrite) throw StateError('测试数据库写入失败');
      mode = (body as Map)['mode'] as String;
      revision++;
      generation++;
    } else if (path.startsWith('overview/')) {
      if (delayed != null) return delayed!.future;
      data = operation(path.split('/').last);
    } else if (path.startsWith('operations/')) {
      data = {
        ...operation('websites'),
        'id': path.split('/').last,
        'state': 'cancelled',
      };
    } else if (path == 'proxy/stop') {
      running = false;
      generation++;
      data = {
        'running': false,
        'traffic': trafficFixture(),
        'historyStorage': {
          'pendingRecords': 0,
          'droppedRecords': 0,
          'error': '',
        },
        'routingMode': mode,
        'networkGeneration': generation,
      };
    }
    return {'revision': revision, 'data': data};
  }

  Map<String, Object> operation(String kind) => {
    'id': 'job-${sequence++}',
    'state': 'succeeded',
    'stage': kind,
    'elapsedMillis': 30,
    'context': {'generation': generation, 'mode': mode, 'kind': kind},
    'result': switch (kind) {
      'latency' => {'latencyMillis': 12.3, 'checkedAt': '2026-10-10T08:00:00Z'},
      'exit-ip' => {
        'ip': '203.0.113.24',
        'country': '日本',
        'city': '东京',
        'provider': provider,
        'checkedAt': '2026-10-10T08:00:00Z',
      },
      _ => {
        'websites': [
          {
            'id': 'github',
            'state': 'reachable',
            'latencyMillis': 186,
            'httpStatus': 200,
          },
          {'id': 'google', 'state': 'timeout'},
          {
            'id': 'youtube',
            'state': 'http_error',
            'latencyMillis': 99,
            'httpStatus': 403,
          },
        ],
      },
    },
  };
}

Future<(Directory, OverviewApi, ProxyController)> fixture() async {
  final directory = await Directory.systemTemp.createTemp('overview-api-');
  final api = OverviewApi();
  final proxy = ProxyController(directory: directory, api: api);
  await proxy.endpointFile.parent.create(recursive: true);
  await proxy.endpointFile.writeAsString(
    jsonEncode({
      'url': 'http://127.0.0.1:12345',
      'token': 'test-token-00000000000000000000000000',
      'apiVersion': 1,
    }),
  );
  await proxy.attach();
  await proxy.refreshConfiguration();
  return (directory, api, proxy);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('概览结果按模式代次隔离，迟到响应不能恢复旧出口', () async {
    final (directory, api, proxy) = await fixture();
    try {
      await proxy.startOverview('exit-ip');
      expect(proxy.overviewOperation('exit-ip')!.result.ip, '203.0.113.24');
      await proxy.setRoutingMode('direct');
      expect(proxy.overviewOperation('exit-ip'), isNull);
      final old = api.operation('exit-ip');
      api.delayed = Completer();
      final pending = proxy.startOverview('exit-ip');
      await Future<void>.delayed(Duration.zero);
      api.mode = 'proxy';
      api.generation++;
      await proxy.attach();
      api.delayed!.complete({'revision': api.revision, 'data': old});
      await pending;
      expect(proxy.overviewOperation('exit-ip'), isNull);
      expect(proxy.overviewBusy('exit-ip'), isFalse);
      final currentGeneration = proxy.networkGeneration;
      api.generation--;
      api.mode = 'direct';
      await proxy.attach();
      expect(proxy.networkGeneration, currentGeneration);
      expect(proxy.routingMode, 'proxy');
      api.generation = currentGeneration;
      api.mode = 'proxy';
      await proxy.stop();
      await expectLater(proxy.startOverview('websites'), throwsStateError);
    } finally {
      proxy.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('切换全局模式保留连接草稿，并让后续提交使用新模式', () async {
    final (directory, api, proxy) = await fixture();
    final model = ProxyViewModel(proxy: proxy, native: TestDesktop(directory))
      ..loading = false;
    model.accept(proxy.appliedProfile!);
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      model.connectionName.text = '未应用名称';
      model.changed('');
      await model.setRoutingMode('direct');
      expect(model.dirty, isTrue);
      expect(model.connectionName.text, '未应用名称');
      expect(model.baseRevision, 2);
      expect(model.draftProfile().routingMode, 'direct');
      expect(proxy.appliedProfile!.selected.name, '默认连接');
      expect(api.calls, isNot(contains('POST config/save')));
      await model.setRoutingMode('rules');
      await model.setRoutingMode('proxy');
      expect(messages, isEmpty);
      api.failWrite = true;
      await model.setRoutingMode('direct');
      await model.setRoutingMode('proxy');
      expect(model.draftProfile().routingMode, 'proxy');
      expect(model.connectionName.text, '未应用名称');
      expect(messages.last.failure, isTrue);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('窗口和页面切换不重测，仅首次概览与实际连接变化自动检测', (tester) async {
    final (directory, api, proxy) = (await tester.runAsync(fixture))!;
    final model = ReadyOverviewModel(proxy, directory);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
    addTearDown(() async {
      model.dispose();
      await directory.delete(recursive: true);
    });
    int requests(String kind) =>
        api.calls.where((call) => call == 'POST overview/$kind').length;
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: ProxyHome(model: model),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests('latency'), 1);
    expect(requests('exit-ip'), 1);
    expect(requests('websites'), 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests('exit-ip'), 1);
    model.navigate(1);
    await tester.pumpAndSettle();
    model.navigate(0);
    await tester.pumpAndSettle();
    expect(requests('exit-ip'), 1);
    await model.setRoutingMode('direct');
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests('latency'), 1);
    expect(requests('exit-ip'), 2);
    await model.stop();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests('exit-ip'), 2);
    model.update(() {
      proxy.running = true;
    });
    await tester.pumpAndSettle();
    expect(requests('exit-ip'), 3);
    await model.startOverview('exit-ip');
    await tester.pumpAndSettle();
    expect(requests('exit-ip'), 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('刷新出口时保留本轮结果和卡片高度，网络变化后清除旧结果', (tester) async {
    final (directory, api, proxy) = (await tester.runAsync(fixture))!;
    final model = ReadyOverviewModel(proxy, directory);
    api.provider = '很长的运营商名称，用来验证多行数据在刷新过程中不会消失并改变卡片高度';
    proxy.appliedProfile = ProxyProfile(
      values: {'server.host': '2001:db8:1000:578c:5400:6ff:fec7:a82c'},
    );
    model.accept(proxy.appliedProfile!);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(() async {
      model.dispose();
      await directory.delete(recursive: true);
    });
    for (final brightness in Brightness.values) {
      for (final width in [1200.0, 900.0, 760.0, 700.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = width == 900
            ? 1.3
            : 1;
        tester.view.physicalSize = Size(width, 2200);
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness),
            home: Scaffold(body: OverviewPage(model: model)),
          ),
        );
        await model.startOverview('exit-ip');
        await tester.pumpAndSettle();
        final exit = find.byKey(const ValueKey('overview-exit-card'));
        final connection = find.byKey(
          const ValueKey('overview-connection-card'),
        );
        final before = tester.getRect(exit);
        if (width >= 760) {
          expect(tester.getRect(connection).top, before.top);
          expect(tester.getRect(connection).bottom, before.bottom);
          expect(
            tester
                .getCenter(
                  find.byKey(
                    const ValueKey('overview-connection-card-divider'),
                  ),
                )
                .dy,
            tester
                .getCenter(
                  find.byKey(const ValueKey('overview-exit-card-divider')),
                )
                .dy,
          );
        }
        api.delayed = Completer();
        await tester.tap(find.text('刷新'));
        await tester.pumpAndSettle();
        expect(find.text('获取中…'), findsOneWidget);
        expect(find.text('203.0.113.24'), findsOneWidget);
        expect(find.text(api.provider), findsOneWidget);
        expect(tester.getRect(exit), before);
        api.delayed!.complete({
          'revision': api.revision,
          'data': api.operation('exit-ip'),
        });
        await tester.pumpAndSettle();
        expect(tester.getRect(exit), before);
        api.delayed = null;
        expect(tester.takeException(), isNull);
      }
    }
    api.delayed = Completer();
    final refresh = model.startOverview('exit-ip');
    await tester.pumpAndSettle();
    final oldResult = api.operation('exit-ip');
    api.generation++;
    await tester.runAsync(() => proxy.attach());
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.24'), findsNothing);
    api.delayed!.complete({'revision': api.revision, 'data': oldResult});
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.24'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('概览真实数据、三种模式和跨平台明暗窄窗口布局', (tester) async {
    final (directory, api, proxy) = (await tester.runAsync(fixture))!;
    final model = ProxyViewModel(proxy: proxy, native: TestDesktop(directory))
      ..loading = false;
    model.accept(proxy.appliedProfile!);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      model.dispose();
      await directory.delete(recursive: true);
    });
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      for (final brightness in Brightness.values) {
        for (final width in [900.0, 480.0, 320.0]) {
          tester.view.physicalSize = Size(width, 1800);
          await tester.pumpWidget(
            MaterialApp(
              theme: desktopTheme(brightness).copyWith(platform: platform),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: model,
                  builder: (_, _) => OverviewPage(model: model),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('重启代理'), findsNothing);
          expect(find.text('当前地址'), findsOneWidget);
        }
      }
    }
    tester.view.physicalSize = const Size(900, 1800);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.24'), findsOneWidget);
    expect(find.text('日本 · 东京'), findsOneWidget);
    await tester.tap(find.text('开始测试'));
    await tester.pumpAndSettle();
    expect(find.text('186 ms'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    expect(find.text('HTTP 403'), findsOneWidget);
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.24'), findsNothing);
    expect(find.text('186 ms'), findsNothing);
    expect(proxy.routingMode, 'direct');
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '检测延迟'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '开始测试'))
          .onPressed,
      isNull,
    );
    expect(api.calls.where((v) => v == 'POST overview/websites').length, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
