import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class _Kernel extends TestKernel {
  final pending = Completer<AccessRecordPage>();
  int requests = 0;
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) {
    requests++;
    return pending.future;
  }

  void complete() => pending.complete(
    AccessRecordPage.fromJson({
      'items': <Map<String, dynamic>>[],
      'hasMore': false,
      'nextValue': 0,
      'nextHost': '',
    }),
  );
}

class _Model extends ProxyViewModel {
  _Model(_Kernel kernel)
    : super(proxy: kernel, native: TestDesktop(Directory.systemTemp)) {
    loading = false;
    page = 4;
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<void> refreshOverview() async {}
}

void main() {
  testWidgets('缓存隧道页通过导航离开后不残留路由菜单', (tester) async {
    tester.view.physicalSize = const Size(1280, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()
      ..connected = true
      ..tunnels = [
        TunnelStatus(
          id: 'menu',
          target: 'test.example:443',
          source: '127.0.0.1:12345',
          route: 'direct',
          state: 'active',
          profileName: '',
          protocol: 'tcp',
          originalProtocol: 'tcp',
          createdAt: DateTime(2026, 10, 17),
        ),
      ];
    final model = _Model(kernel);
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tunnel-route-menu')));
    await tester.pumpAndSettle();
    expect(find.text('恢复自动路由'), findsOneWidget);
    model.navigate(1);
    await tester.pumpAndSettle();
    expect(find.text('恢复自动路由'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final wholeApp in [false, true]) {
    testWidgets('缓存中的加载页隐藏后停止动画，返回后继续等待：主页面=$wholeApp', (tester) async {
      tester.view.physicalSize = const Size(1280, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final kernel = _Kernel()..connected = true;
      final model = _Model(kernel);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        wholeApp
            ? NetworkApp(model: model)
            : MaterialApp(
                theme: desktopTheme(Brightness.light),
                home: Scaffold(body: TunnelsPage(model: model)),
              ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('访问记录'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(kernel.requests, 1);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      if (wholeApp) {
        model.navigate(1);
      } else {
        await tester.tap(find.text('实时隧道'));
      }
      // 等待可见控件的点击反馈结束，再检查隐藏页是否仍有持续动画。
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 3),
      );
      expect(tester.binding.transientCallbackCount, 0);
      if (wholeApp) {
        model.navigate(4);
      } else {
        await tester.tap(find.text('访问记录'));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(kernel.requests, 1, reason: '保留原请求，不因返回缓存页再次查询');
      kernel.complete();
      await tester.pumpAndSettle();
      expect(find.text('暂无访问记录'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
