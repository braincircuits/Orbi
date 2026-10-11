import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/services/runtime_preferences.dart';
import 'package:network_ui/ui/pages/diagnostics_page.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class _Desktop extends NativeBridge {
  @override
  Future<Map<String, String>> environment() async => {
    'support': Directory.systemTemp.path,
    'resources': Directory.systemTemp.path,
  };

  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

class _Preferences extends RuntimePreferences {
  @override
  Future<RuntimePaths> read(Directory directory) async =>
      const RuntimePaths('', '');
}

class _Kernel extends ProxyController {
  @override
  Future<void> startOverview(String kind) async {}

  final connectionReady = Completer<void>();
  final startReady = Completer<void>();
  bool failStart = false;
  bool failApply = false;
  Completer<void>? applyReady;
  int starts = 0, stops = 0, restarts = 0, disconnects = 0;

  @override
  Future<void> connect(
    ProxyProfile profile,
    String resources, {
    bool launch = true,
  }) async {
    await connectionReady.future;
    connected = true;
    appliedProfile = ProxyProfile(values: {'server.host': 'proxy.test'});
    defaultConnectionId = appliedProfile!.defaultConnectionId;
    notifyListeners();
  }

  @override
  Future<int?> start(
    ProxyProfile profile,
    String resources, {
    bool applyDraft = true,
    int? expectedRevision,
  }) async {
    starts++;
    await startReady.future;
    if (failStart) throw StateError('测试端口被占用');
    running = true;
    address = '127.0.0.1:8080';
    notifyListeners();
    return null;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
    notifyListeners();
  }

  @override
  Future<void> restart() async {
    restarts++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<int> apply(
    ProxyProfile profile,
    String resources, {
    int? expectedRevision,
  }) async {
    await applyReady?.future;
    if (failApply) throw StateError('测试配置无效');
    appliedProfile = profile;
    configurationRevision = ++revision;
    notifyListeners();
    return revision;
  }

  @override
  Future<void> refreshConfiguration() async {}
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
  });

  for (final failStart in [false, true]) {
    testWidgets('首帧显示概览，慢连接和自动启动${failStart ? '失败' : '完成'}不会显示空白', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1120, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final kernel = _Kernel()..failStart = failStart;
      final model = ProxyViewModel(
        proxy: kernel,
        native: _Desktop(),
        preferences: _Preferences(),
      );
      addTearDown(model.dispose);
      await tester.pumpWidget(NetworkApp(model: model));
      expect(find.text('正在连接代理内核'), findsOneWidget);
      expect(find.text('本地 HTTP 代理'), findsOneWidget);
      expect(find.text('活跃隧道'), findsNWidgets(2));
      expect(find.text('服务已停止'), findsNothing);
      expect(find.byKey(const ValueKey('startup-progress')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('流量趋势'), findsOneWidget);
      kernel.connectionReady.complete();
      await tester.pump();
      expect(find.text('正在启动代理'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '准备中…'), findsOneWidget);
      expect(kernel.starts, 1);
      kernel.startReady.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('startup-progress')), findsNothing);
      expect(model.locked, isFalse);
      expect(find.text(failStart ? '开启' : '停止'), findsOneWidget);
      if (failStart) {
        expect(find.textContaining('自动启动代理失败'), findsOneWidget);
        kernel.failStart = false;
        await tester.tap(find.text('开启'));
        await tester.pumpAndSettle();
        expect(kernel.starts, 2);
        expect(find.text('停止'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('代理开关采用原型样式，文字对比清晰且明暗模式操作有效', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final kernel = _Kernel()
      ..connectionReady.complete()
      ..startReady.complete();
    final model = ProxyViewModel(
      proxy: kernel,
      native: _Desktop(),
      preferences: _Preferences(),
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final stop = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '停止'),
      );
      final stopColor = stop.style!.backgroundColor!.resolve({})!;
      expect(
        stopColor,
        Color.alphaBlend(
          Theme.of(tester.element(find.text('停止'))).colorScheme.error
              .withValues(alpha: .08),
          Theme.of(tester.element(find.text('停止')))
              .colorScheme
              .surfaceContainerLowest,
        ),
      );
      final foreground = stop.style!.foregroundColor!.resolve({})!;
      expect(contrast(foreground, stopColor), greaterThanOrEqualTo(4.5));
      expect(
        stopColor,
        isNot(Theme.of(tester.element(find.text('停止'))).colorScheme.primary),
      );
      expect(find.text('重启代理'), findsNothing);
      expect(find.text('更多操作'), findsNothing);
      await tester.ensureVisible(find.text('停止'));
      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开启'),
      );
      final startColor = start.style!.backgroundColor!.resolve({})!;
      expect(
        startColor,
        Color.alphaBlend(
          Theme.of(tester.element(find.text('开启'))).colorScheme.primary
              .withValues(alpha: .08),
          Theme.of(tester.element(find.text('开启')))
              .colorScheme
              .surfaceContainerLowest,
        ),
      );
      expect(
        contrast(start.style!.foregroundColor!.resolve({})!, startColor),
        greaterThanOrEqualTo(4.5),
      );
      await tester.tap(find.text('开启'));
      await tester.pumpAndSettle();
      expect(find.text('停止'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(kernel.stops, 2);
    expect(kernel.restarts, 0);
    expect(kernel.disconnects, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('概览只读展示当前地址、复制实际地址并直接提示连接失败', (tester) async {
    tester.view.physicalSize = const Size(864, 642);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()
      ..connectionReady.complete()
      ..startReady.complete();
    final model = ProxyViewModel(
      proxy: kernel,
      native: _Desktop(),
      preferences: _Preferences(),
    );
    addTearDown(model.dispose);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('服务运行中'), findsOneWidget);
    expect(find.text('等待建立'), findsNothing);
    final overviewScrollable = find.descendant(of: find.byKey(const PageStorageKey('overview')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('proxy.test:4433'), 250, scrollable: overviewScrollable);
    expect(find.text('proxy.test:4433'), findsOneWidget);
    expect(find.text('默认连接'), findsOneWidget);
    expect(find.text('连接详情'), findsNothing);
    tester.state<ScrollableState>(overviewScrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制本地代理地址'));
    await tester.pumpAndSettle();
    expect(copied, '127.0.0.1:8080');
    model.update(() {
      kernel.connection = 'failed';
      model.fields['port']!.text = '9999';
    });
    await tester.pumpAndSettle();
    expect(find.text('服务端连接失败，请检查连接配置或运行连接诊断。'), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(find.text('127.0.0.1:8080'), findsOneWidget);
    expect(find.text('127.0.0.1:9999'), findsNothing);
    for (final size in [const Size(720, 540), const Size(480, 640)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('开启'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('隧道列表排在诊断之前，快捷键同步且默认测试谷歌地址', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()
      ..connectionReady.complete()
      ..startReady.complete();
    final model = ProxyViewModel(
      proxy: kernel,
      native: _Desktop(),
      preferences: _Preferences(),
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('活跃隧道').first).dy,
      lessThan(tester.getCenter(find.text('连接诊断')).dy),
    );
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(find.byType(TunnelsPage), findsOneWidget);
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      final target = find.descendant(
        of: find.byType(DiagnosticsPage),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(target).controller!.text,
        'www.google.com:443',
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑器保存栏显示草稿及保存结果，明暗切换保留提示且处理中禁用', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final kernel = _Kernel()
      ..connectionReady.complete()
      ..startReady.complete();
    final model = ProxyViewModel(
      proxy: kernel,
      native: _Desktop(),
      preferences: _Preferences(),
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    final apply = find.widgetWithText(FilledButton, '应用并保存');
    await tester.tap(find.byKey(const ValueKey('edit-default')));
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsOneWidget);
    final host = find.byKey(const ValueKey('field-server.host'));
    await tester.ensureVisible(host);
    await tester.enterText(host, 'changed.test');
    await tester.pumpAndSettle();
    expect(find.text('有未应用的编辑'), findsOneWidget);
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      expect(find.text('有未应用的编辑'), findsOneWidget);
    }
    kernel.applyReady = Completer<void>();
    kernel.failApply = true;
    await tester.tap(apply);
    await tester.pump();
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    kernel.applyReady!.complete();
    await tester.pumpAndSettle();
    expect(find.text('有未应用的编辑'), findsOneWidget);
    expect(model.dirty, isTrue);
    kernel.failApply = false;
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsOneWidget);
    expect(find.text('所有配置已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
