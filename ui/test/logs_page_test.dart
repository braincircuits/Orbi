import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/services/proxy_controller.dart' show KernelLog;
import 'package:network_ui/ui/pages/logs_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class _LogKernel extends TestKernel {
  int reads = 0;
  @override
  List<KernelLog> get logs {
    reads++;
    return super.logs;
  }
}

class _Desktop extends TestDesktop {
  _Desktop() : super(Directory.systemTemp);
  String exported = '';
  @override
  Future<String?> exportLogs(String contents) async {
    exported = contents;
    return null;
  }
}

void main() {
  late _LogKernel kernel;
  late _Desktop desktop;
  late ProxyViewModel model;
  setUp(() {
    kernel = _LogKernel();
    desktop = _Desktop();
    model = ProxyViewModel(proxy: kernel, native: desktop)
      ..loading = false
      ..page = 3;
    kernel.addLog('INFO api.example.com 已连接');
    kernel.addLog('ERROR API.example.com 连接失败');
    kernel.addLog('WARN dns.example.com 响应超时');
  });
  tearDown(() => model.dispose());

  Future<void> mount(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.macOS,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: model,
        builder: (context, _) => MaterialApp(
          theme: desktopTheme(brightness).copyWith(platform: platform),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: LogsPage(model: model),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('关键词和级别可叠加筛选，导出仅含当前结果，清空搜索保留原始日志', (tester) async {
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('log-search')),
      ' api.EXAMPLE ',
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 条'), findsOneWidget);
    expect(find.text('dns.example.com 响应超时'), findsNothing);
    await tester.tap(find.text('所有级别'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'ERROR').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 3 条'), findsOneWidget);
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(desktop.exported, contains('API.example.com 连接失败'));
    expect(desktop.exported, isNot(contains('已连接')));
    expect(desktop.exported, isNot(contains('响应超时')));
    await tester.enterText(find.byKey(const ValueKey('log-search')), '不存在的目标');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的日志'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '导出'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('清空日志搜索'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3 条'), findsOneWidget);
    expect(kernel.logs, hasLength(3));
  });

  testWidgets('搜索期间暂停保留快照，恢复后显示新匹配日志', (tester) async {
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('log-search')),
      'api.example',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('暂停日志'));
    await tester.pumpAndSettle();
    kernel.reads = 0;
    kernel.addLog('INFO api.example.com 新请求');
    await tester.pumpAndSettle();
    expect(find.text('api.example.com 新请求'), findsNothing);
    expect(kernel.reads, 0, reason: '暂停显示时不重复读取和过滤后台日志');
    expect(find.text('2 / 3 条'), findsOneWidget);
    await tester.tap(find.byTooltip('恢复日志'));
    await tester.pumpAndSettle();
    expect(find.text('api.example.com 新请求'), findsOneWidget);
    expect(find.text('3 / 4 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('日志工具栏在窄窗口和大字下可用：$platform/$brightness', (tester) async {
        tester.view.physicalSize = const Size(440, 420);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await mount(tester, platform: platform, brightness: brightness);
        await tester.enterText(find.byKey(const ValueKey('log-search')), 'api');
        await tester.pumpAndSettle();
        expect(find.text('2 / 3 条'), findsOneWidget);
        expect(find.text('导出').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
