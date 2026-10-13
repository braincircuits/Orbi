import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/overview_page.dart';
import 'package:network_ui/ui/pages/settings_dialog.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

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

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('虚拟网卡开关显示启停状态 $platform $brightness', (tester) async {
        final (directory, api, proxy) = (await tester.runAsync(fixture))!;
        final model = ProxyViewModel(
          proxy: proxy,
          native: TunDesktop(directory),
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
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
