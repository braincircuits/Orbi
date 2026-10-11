import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/configuration_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class SwitchingKernel extends TestKernel {
  final selections = <String>[];
  bool failSwitch = false;
  Completer<void>? pendingSwitch;
  @override
  Future<int> selectConnection(String id, {int? expectedRevision}) async {
    selections.add(id);
    expect(expectedRevision, configurationRevision);
    await pendingSwitch?.future;
    if (failSwitch) throw StateError('测试切换失败');
    final previous = appliedProfile!;
    defaultConnectionId = id;
    final profile = ProxyProfile(
      connections: previous.connections.map((c) => c.copy()).toList(),
      defaultConnectionId: id,
      values: previous.values,
      rules: previous.rules,
    );
    publish(profile, configurationRevision + 1);
    return configurationRevision;
  }
}

ProxyProfile connections(int count, {String active = 'node-0'}) => ProxyProfile(
  defaultConnectionId: active,
  connections: List.generate(
    count,
    (i) => ConnectionProfile(
      id: 'node-$i',
      name: '连接 $i',
      hasPassword: true,
      config: {
        'server.host': 'proxy-$i.example.com',
        'protocol': i.isEven ? 'http2' : 'http3',
      },
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SwitchingKernel kernel;
  late ProxyViewModel model;
  setUp(() {
    kernel = SwitchingKernel();
    kernel.publish(connections(100), 1);
    kernel.defaultConnectionId = 'node-0';
    model = ProxyViewModel(
      proxy: kernel,
      native: TestDesktop(Directory.systemTemp),
    )..loading = false;
    model.accept(kernel.appliedProfile!);
  });
  tearDown(() => model.dispose());

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(1120, 780),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(brightness),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) => ConfigurationPage(model: model),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('切换仅写默认路由，保留所有配置草稿和新密码并更新版本', () async {
    model.connectionName.text = '尚未应用的名称';
    model.fields['password']!.text = '草稿密码';
    model.fields['port']!.text = '8888';
    model.rules.text = 'DIRECT draft.example';
    model.changed('');
    model.addConnection();
    final editing = model.editingId;
    await model.switchConnection('node-1');
    expect(kernel.selections, ['node-1']);
    expect(kernel.writes, isEmpty);
    expect(kernel.appliedProfile!.connections.first.name, '连接 0');
    expect(
      kernel.appliedProfile!.connections.first.values['password'],
      isEmpty,
    );
    expect(model.connectionDrafts.first.values['password'], '草稿密码');
    expect(model.connectionDrafts.first.name, '尚未应用的名称');
    expect(model.connectionDrafts.length, 101);
    expect(model.editingId, editing);
    expect(model.fields['port']!.text, '8888');
    expect(model.rules.text, 'DIRECT draft.example');
    expect(model.defaultId, 'node-1');
    expect(model.baseRevision, 2);
    expect(model.dirty, isTrue);
    model.discardDrafts();
    expect(model.defaultId, 'node-1');
    expect(model.connectionDrafts.length, 100);
    expect(model.connectionDrafts.first.values['password'], isEmpty);
  });

  test('切换失败保留当前连接和草稿，未应用的新连接不能切换', () async {
    kernel.failSwitch = true;
    model.connectionName.text = '草稿';
    model.changed('');
    await model.switchConnection('node-1');
    expect(model.defaultId, 'node-0');
    expect(model.connectionName.text, '草稿');
    expect(model.dirty, isTrue);
    model.addConnection();
    await model.switchConnection(model.editingId);
    expect(kernel.selections, ['node-1']);
    expect(kernel.writes, isEmpty);
  });

  test('切换事务失败保留草稿和原默认连接', () async {
    kernel.failSwitch = true;
    model.connectionName.text = '草稿';
    model.changed('');
    final messages = <String>[];
    final subscription = model.messages.stream.listen(
      (event) => messages.add(event.text),
    );
    await model.switchConnection('node-1');
    expect(model.defaultId, 'node-0');
    expect(model.connectionName.text, '草稿');
    expect(model.dirty, isTrue);
    expect(model.baseRevision, 1);
    expect(messages.last, contains('测试切换失败'));
    await subscription.cancel();
  });

  testWidgets('卡片点击编辑不切换，使用按钮切换且保留草稿，忙碌时防止重复请求', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('edit-node-1')));
    await tester.pumpAndSettle();
    expect(kernel.selections, isEmpty);
    expect(model.editingId, 'node-1');
    await tester.enterText(
      find.byKey(const ValueKey('connection-name')),
      '编辑草稿',
    );
    kernel.pendingSwitch = Completer<void>();
    final switchButton = find.byKey(const ValueKey('switch-node-1'));
    await tester.ensureVisible(switchButton);
    await tester.tap(switchButton);
    await tester.pump();
    expect(tester.widget<TextButton>(switchButton).onPressed, isNull);
    expect(kernel.selections, ['node-1']);
    expect(find.byType(AlertDialog), findsNothing);
    kernel.pendingSwitch!.complete();
    await tester.pumpAndSettle();
    expect(model.defaultId, 'node-1');
    expect(model.editingId, 'node-1');
    expect(model.connectionName.text, '编辑草稿');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击卡片立即切换且保留草稿，编辑按钮只打开编辑面板', (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('connection-name')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('edit-node-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('connection-name')),
      '保留草稿',
    );
    final editing = model.editingId;
    await tester.tap(find.byTooltip('收起编辑面板（保留草稿）'));
    await tester.pumpAndSettle();
    kernel.pendingSwitch = Completer<void>();
    final body = find.byKey(const ValueKey('card-body-node-1'));
    await tester.tap(body);
    await tester.pump();
    expect(kernel.selections, ['node-1']);
    expect(tester.widget<InkWell>(body).onTap, isNull);
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('card-body-node-2')))
          .onTap,
      isNull,
    );
    expect(find.byKey(const ValueKey('connection-name')), findsNothing);
    expect(find.text('切换中…'), findsWidgets);
    await tester.tap(body);
    await tester.pump();
    expect(kernel.selections, ['node-1']);
    kernel.pendingSwitch!.complete();
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('connection-node-1'));
    expect(
      find.descendant(of: current, matching: find.text('使用中')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: current, matching: find.text('当前连接')),
      findsOneWidget,
    );
    expect(tester.widget<InkWell>(body).onTap, isNull);
    expect(model.editingId, editing);
    expect(model.connectionName.text, '保留草稿');
    await tester.tap(find.byKey(const ValueKey('edit-node-2')));
    await tester.pumpAndSettle();
    expect(model.editingId, 'node-2');
    expect(find.byKey(const ValueKey('connection-name')), findsOneWidget);
    expect(kernel.selections, ['node-1']);
    expect(model.connectionDrafts.first.name, '保留草稿');
    expect(tester.takeException(), isNull);
  });

  testWidgets('未应用的新连接不能通过卡片直接切换', (tester) async {
    await show(tester);
    await tester.tap(find.text('添加连接'));
    await tester.pumpAndSettle();
    final id = model.editingId;
    await tester.enterText(
      find.byKey(const ValueKey('connection-search')),
      model.editingConnection.name,
    );
    await tester.pumpAndSettle();
    final body = find.byKey(ValueKey('card-body-$id'));
    expect(tester.widget<InkWell>(body).onTap, isNull);
    expect(find.text('待应用'), findsOneWidget);
    await tester.tap(body);
    expect(kernel.selections, isEmpty);
  });

  testWidgets('连接工具栏等高，卡片适应三种桌面平台、明暗主题和窗口宽度', (tester) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      for (final brightness in Brightness.values) {
        for (final size in [const Size(1120, 780), const Size(620, 540)]) {
          await show(tester, size: size, brightness: brightness);
          expect(
            tester
                .getSize(find.byKey(const ValueKey('connection-search')))
                .height,
            DesktopDesign.controlHeight,
          );
          expect(
            tester.getSize(find.byType(SegmentedButton<bool>)).height,
            DesktopDesign.controlHeight,
          );
          expect(find.text('使用中'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('搜索、协议筛选、列表和定位可组合，独立滚动加载不移动编辑区', (tester) async {
    await show(tester);
    final search = find.byKey(const ValueKey('connection-search'));
    await tester.enterText(search, 'proxy-99.example.com');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-node-99')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-node-0')), findsNothing);
    await tester.tap(find.text('全部协议'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MenuItemButton).hitTestable().at(1));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的连接'), findsOneWidget);
    await tester.tap(find.text('定位当前'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.text('全部协议'), findsOneWidget);
    final editorRect = tester.getRect(
      find.byKey(const ValueKey('connection-name')),
    );
    final scrollable = find.descendant(
      of: find.byKey(const PageStorageKey('connection-collection')),
      matching: find.byType(Scrollable),
    );
    for (
      var attempt = 0;
      attempt < 30 &&
          find
              .byKey(const ValueKey('edit-node-70'))
              .hitTestable()
              .evaluate()
              .isEmpty;
      attempt++
    ) {
      await tester.drag(scrollable, const Offset(0, -350));
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('edit-node-70')).hitTestable(),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('connection-name'))),
      editorRect,
    );
    kernel.defaultConnectionId = 'node-99';
    model.update(() {});
    await tester.pump();
    await tester.tap(find.text('定位当前'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-node-99')), findsOneWidget);
    final collectionBounds = tester.getRect(scrollable);
    expect(
      collectionBounds.contains(
        tester.getCenter(find.byKey(const ValueKey('edit-node-99'))),
      ),
      isTrue,
    );
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位当前'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-node-99')), findsOneWidget);
    expect(
      tester
          .getRect(scrollable)
          .contains(
            tester.getCenter(find.byKey(const ValueKey('edit-node-99'))),
          ),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空连接、窄窗口及长名称布局可用，密码切换编辑后重新隐藏', (tester) async {
    model.connectionDrafts.first.name = '很长的连接名称' * 10;
    await show(tester, size: const Size(620, 540));
    expect(tester.takeException(), isNull);
    model.showPassword = true;
    model.editConnection('node-1');
    expect(model.showPassword, isFalse);
    kernel.publish(connections(0, active: ''), 2);
    await tester.pumpAndSettle();
    expect(find.text('添加你的第一个连接'), findsOneWidget);
    await tester.tap(find.text('添加连接'));
    await tester.pumpAndSettle();
    expect(model.connectionDrafts, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
