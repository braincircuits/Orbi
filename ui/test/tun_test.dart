import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/overview_page.dart';
import 'package:network_ui/ui/pages/settings_dialog.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';
import 'package:network_ui/models/tun_engine.dart';
import 'package:network_ui/services/runtime_preferences.dart';
import 'package:network_ui/ui/widgets/desktop_select.dart';

import 'overview_test.dart' show fixture;
import 'view_model_test.dart' show TestDesktop;

class TunDesktop extends TestDesktop {
  TunDesktop(super.directory);
  bool fail = false;
  bool installed = true;
  bool failRemoval = false;
  int removals = 0;
  @override
  Future<bool> tunServiceInstalled() async => installed;
  @override
  Future<void> removeTunService() async {
    removals++;
    if (failRemoval) throw StateError('已取消卸载授权');
    installed = false;
  }

  final tickets = <String>[];
  @override
  Future<void> startTun(String endpoint, String ticket) async {
    expect(File(endpoint).isAbsolute, isTrue);
    tickets.add(ticket);
    if (fail) throw StateError('测试授权失败');
  }
}

// 界面测试使用内存偏好，真实文件持久化由上面的会话测试覆盖。
class TunPreferences extends RuntimePreferences {
  RuntimePaths saved = const RuntimePaths('', '');
  @override
  Future<RuntimePaths> read(Directory directory) async => saved;
  @override
  Future<void> write(Directory directory, RuntimePaths paths) async =>
      saved = paths;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('虚拟网卡活动时拒绝卸载，取消授权保留服务，成功后刷新状态', () async {
    final (directory, _, proxy) = await fixture();
    final native = TunDesktop(directory);
    final model = ProxyViewModel(proxy: proxy, native: native)..loading = false;
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.refreshTunService();
      proxy.tunState = 'running';
      await model.removeTunService();
      expect(native.removals, 0);
      proxy.tunState = 'off';
      native.failRemoval = true;
      await model.removeTunService();
      expect(model.tunServiceInstalled, isTrue);
      native.failRemoval = false;
      await model.removeTunService();
      expect(native.removals, 2);
      expect(model.tunServiceInstalled, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(messages.map((message) => message.failure), [true, true, false]);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  for (final brightness in Brightness.values) {
    testWidgets('设置页确认卸载及取消 $brightness', (tester) async {
      final (directory, _, proxy) = (await tester.runAsync(fixture))!;
      final native = TunDesktop(directory);
      final model = ProxyViewModel(proxy: proxy, native: native)
        ..loading = false;
      model.accept(proxy.appliedProfile!);
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        model.dispose();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(brightness),
          home: Scaffold(body: SettingsDialog(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('remove-tun-service'));
      await tester.scrollUntilVisible(
        button,
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('settings')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('卸载系统辅助服务？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(native.removals, 0);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('卸载'));
      await tester.pumpAndSettle();
      expect(native.removals, 1);
      expect(model.tunServiceInstalled, isFalse);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(find.text('系统辅助服务已卸载，配置和访问记录已保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, skip: !Platform.isMacOS);
  }

  test('启动失败及授权取消均撤销内核启动标识', () async {
    final (directory, api, proxy) = await fixture();
    final native = TunDesktop(directory);
    final model = ProxyViewModel(proxy: proxy, native: native)..loading = false;
    try {
      await model.setTun(true);
      expect(proxy.tunState, 'authorizing');
      expect(native.tickets, ['启动标识-1']);
      await model.setTun(false);
      expect(proxy.tunEnabled, isFalse);
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '启动标识-1', 'error': ''}),
      );
      native.fail = true;
      await model.setTun(true);
      expect(proxy.tunEnabled, isFalse);
      native.fail = false;
      await model.setTun(true);
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '启动标识-1', 'error': '迟到的退出'}),
      );
      expect(proxy.tunEnabled, isTrue);
      await model.handleNativeCall(
        const MethodCall('tunExited', {
          'ticket': '启动标识-3',
          'error': '已取消管理员授权',
        }),
      );
      expect(proxy.tunEnabled, isFalse);
      expect(api.calls.where((call) => call == 'POST tun/stop'), hasLength(3));
    } finally {
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  for (final failRouting in [false, true]) {
    test('路由操作结束后清理 TUN 授权，路由失败=$failRouting', () async {
      final (directory, api, proxy) = await fixture();
      final native = TunDesktop(directory);
      final model = ProxyViewModel(proxy: proxy, native: native)
        ..loading = false;
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      try {
        await model.setTun(true);
        api.routingGate = Completer<void>();
        api.failWrite = failRouting;
        final changing = model.setRoutingMode('direct');
        expect(proxy.busy, isTrue);
        var exited = false;
        final exit = model
            .handleNativeCall(
              const MethodCall('tunExited', {
                'ticket': '启动标识-1',
                'error': '已取消管理员授权',
              }),
            )
            .then((_) => exited = true);
        await Future<void>.delayed(Duration.zero);
        expect(exited, isFalse);
        expect(api.calls, isNot(contains('POST tun/stop')));
        api.routingGate!.complete();
        await Future.wait([changing, exit]).timeout(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(api.tunState, 'off');
        expect(
          messages.any((message) => message.text.contains('已取消管理员授权')),
          isTrue,
        );
        expect(
          api.calls.where((call) => call == 'POST tun/stop'),
          hasLength(1),
        );
        await model.setTun(true);
        expect(native.tickets, hasLength(2));
      } finally {
        await subscription.cancel();
        model.dispose();
        await directory.delete(recursive: true);
      }
    });
  }

  test('TUN 退出清理失败时同时显示授权错误和清理错误', () async {
    final (directory, api, proxy) = await fixture();
    final model = ProxyViewModel(proxy: proxy, native: TunDesktop(directory))
      ..loading = false;
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.setTun(true);
      api.failTunStop = true;
      await model.handleNativeCall(
        const MethodCall('tunExited', {
          'ticket': '启动标识-1',
          'error': '已取消管理员授权',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(messages.last.text, contains('已取消管理员授权'));
      expect(messages.last.text, contains('测试 TUN 清理失败'));
      api.failTunStop = false;
      await model.setTun(false);
      expect(api.tunState, 'off');
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('界面释放会结束排队的 TUN 清理，不再请求内核', () async {
    final (directory, api, proxy) = await fixture();
    final model = ProxyViewModel(proxy: proxy, native: TunDesktop(directory))
      ..loading = false;
    await model.setTun(true);
    api.routingGate = Completer<void>();
    final changing = model.setRoutingMode('direct');
    final exit = model.handleNativeCall(
      const MethodCall('tunExited', {'ticket': '启动标识-1', 'error': '已取消管理员授权'}),
    );
    model.dispose();
    try {
      await exit.timeout(const Duration(seconds: 2));
      expect(api.calls, isNot(contains('POST tun/stop')));
    } finally {
      api.routingGate!.complete();
      await changing;
      await directory.delete(recursive: true);
    }
  });

  test('关闭时只保存组件，运行中等待旧进程退出和路由清理后重新启动', () async {
    final (directory, api, proxy) = await fixture();
    final native = TunDesktop(directory);
    final model = ProxyViewModel(proxy: proxy, native: native)..loading = false;
    try {
      await RuntimePreferences().write(
        directory,
        const RuntimePaths('/java', '/client.jar'),
      );
      await model.setTunEngine(TunEngine.tun2socks);
      expect(native.tickets, isEmpty);
      final saved = await RuntimePreferences().read(directory);
      expect(saved.tunEngine, TunEngine.tun2socks);
      expect(saved.javaPath, '/java');
      expect(saved.jarPath, '/client.jar');
      await model.setTun(true);
      expect(api.requestedTunEngines, ['tun2socks']);
      api.tunState = 'running';
      await proxy.attach();
      api.delayTunStop = true;
      final switching = model.setTunEngine(TunEngine.outline);
      await Future<void>.delayed(Duration.zero);
      expect(proxy.tunState, 'stopping');
      expect(model.switchingTunEngine, isTrue);
      expect(native.tickets, hasLength(1));
      // 重复选择不能启动第二个切换；迟到的其他会话退出不能解锁本次等待。
      await model.setTunEngine(TunEngine.outline);
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '其他会话', 'error': ''}),
      );
      expect(native.tickets, hasLength(1));
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '启动标识-1', 'error': ''}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(native.tickets, hasLength(1));
      api.tunState = 'off';
      await switching.timeout(const Duration(seconds: 2));
      expect(api.requestedTunEngines, ['tun2socks', 'outline']);
      expect(native.tickets, hasLength(2));
      expect(proxy.tunState, 'authorizing');
      expect(model.switchingTunEngine, isFalse);
      expect(
        (await RuntimePreferences().read(directory)).tunEngine,
        TunEngine.outline,
      );
    } finally {
      model.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test('旧会话清理失败时不启动新组件，新组件启动失败后撤销启动标识', () async {
    final (directory, api, proxy) = await fixture();
    final native = TunDesktop(directory);
    final model = ProxyViewModel(proxy: proxy, native: native)..loading = false;
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.setTun(true);
      api.tunState = 'running';
      await proxy.attach();
      final failed = model.setTunEngine(TunEngine.tun2socks);
      await Future<void>.delayed(Duration.zero);
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '启动标识-1', 'error': '路由清理失败'}),
      );
      await failed;
      expect(native.tickets, hasLength(1));
      expect(model.tunEngine, TunEngine.outline);
      expect(messages.last.text, contains('路由清理失败'));
      // 再次启动旧组件，然后验证新组件启动失败不会自动回退。
      await model.setTun(true);
      api.tunState = 'running';
      await proxy.attach();
      native.fail = true;
      final switching = model.setTunEngine(TunEngine.tun2socks);
      await Future<void>.delayed(Duration.zero);
      await model.handleNativeCall(
        const MethodCall('tunExited', {'ticket': '启动标识-2', 'error': ''}),
      );
      await switching;
      expect(api.requestedTunEngines, ['outline', 'outline', 'tun2socks']);
      expect(proxy.tunEnabled, isFalse);
      expect(model.tunEngine, TunEngine.tun2socks);
      expect(model.switchingTunEngine, isFalse);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('虚拟网卡开关显示启停状态 $platform $brightness', (tester) async {
        final (directory, api, proxy) = (await tester.runAsync(fixture))!;
        final preferences = TunPreferences();
        final model = ProxyViewModel(
          proxy: proxy,
          native: TunDesktop(directory),
          preferences: preferences,
        )..loading = false;
        model.accept(proxy.appliedProfile!);
        tester.view.physicalSize = const Size(1000, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          model.dispose();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness).copyWith(platform: platform),
            home: Scaffold(body: OverviewPage(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        final finder = find.byKey(const ValueKey('overview-tun'));
        expect(tester.widget<Switch>(finder).value, isFalse);
        final selector = find.byKey(const ValueKey('overview-tun-engine'));
        expect(
          tester.widget<DesktopSelect<TunEngine>>(selector).value,
          TunEngine.outline,
        );
        expect(find.text('TUN 转发组件'), findsOneWidget);
        if (proxy.tunSupported) {
          await tester.tap(
            find.descendant(of: selector, matching: find.byType(TextField)),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .widgetWithText(MenuItemButton, 'xjasonlyu/tun2socks')
                .hitTestable(),
          );
          await tester.pumpAndSettle();
          expect(model.working, isFalse);
          expect(preferences.saved.tunEngine, TunEngine.tun2socks);
          expect(model.tunEngine, TunEngine.tun2socks);
          expect(api.requestedTunEngines, isEmpty);
        }
        api.tunState = 'starting';
        await tester.runAsync(() => proxy.attach());
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness).copyWith(platform: platform),
            home: Scaffold(body: OverviewPage(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(finder).value, isTrue);
        expect(tester.widget<Switch>(finder).onChanged, isNull);
        expect(
          tester.widget<DesktopSelect<TunEngine>>(selector).onSelected,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
