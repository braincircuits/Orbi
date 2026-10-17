import 'dart:async';
import 'dart:io';
import 'dart:ui' as painting;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/direct_rule_entry.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/kernel_api_client.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/routes_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class RulesKernel extends TestKernel {
  Completer<void>? modeResult;
  Completer<void>? validationResult;
  bool failMode = false;
  @override
  Future<int> setRoutingMode(String mode, {int? expectedRevision}) async {
    busy = true;
    notifyListeners();
    try {
      await modeResult?.future;
      if (failMode) throw StateError('模式切换失败');
      routingMode = mode;
      publish(copyProfile()..routingMode = mode, configurationRevision + 1);
      return configurationRevision;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  final ruleWrites = <String>[];
  final targetWrites = <(String, String)>[];
  final jobs = <String, DiagnosticOperation>{};
  bool failRules = false, conflictRules = false;
  @override
  Map<String, DiagnosticOperation> get operations => jobs;

  ProxyProfile copyProfile() =>
      ProxyProfile.fromKernel(appliedProfile!.runtimeConfiguration);

  @override
  Future<void> validateDirectRules(String rules) async {
    await validationResult?.future;
    if (rules.contains('https://')) {
      throw KernelApiException('INVALID_RULE', '直连规则无效，位置：直连规则:1');
    }
  }

  @override
  Future<int> updateDirectRules(String rules, {int? expectedRevision}) async {
    expect(expectedRevision, configurationRevision);
    if (conflictRules) {
      publish(
        copyProfile()..rules = 'external.example',
        configurationRevision + 1,
      );
      throw KernelApiException('REVISION_CONFLICT', '配置版本冲突');
    }
    if (failRules) throw StateError('规则写入失败');
    await validateDirectRules(rules);
    ruleWrites.add(rules);
    publish(copyProfile()..rules = rules, configurationRevision + 1);
    return configurationRevision;
  }

  @override
  Future<int> routeTarget(
    String target,
    String route, {
    int? expectedRevision,
  }) async {
    expect(expectedRevision, configurationRevision);
    targetWrites.add((target, route));
    final host = Uri.parse('http://$target').host
        .replaceAll(RegExp(r'^\[|\]$'), '');
    final profile = copyProfile();
    final targets = profile.targetRoutes;
    if (route == 'auto') {
      targets.remove(host);
    } else {
      targets[host] = route;
    }
    profile.routesOverrides = targets.entries
        .map((e) => '${e.value} ${e.key}')
        .join('\n');
    publish(profile, configurationRevision + 1);
    return configurationRevision;
  }

  @override
  Future<String> resolveRoute(String target) async {
    final id = 'query-${jobs.length}';
    jobs[id] = DiagnosticOperation.fromJson({
      'id': id,
      'state': 'succeeded',
      'stage': 'routing',
      'elapsedMillis': 1,
      'result': {
        'action': appliedProfile!.targetRoutes.isEmpty ? 'direct' : 'proxy',
        'matchedBy': appliedProfile!.targetRoutes.isEmpty
            ? 'direct_rule'
            : 'target_rule',
      },
    });
    notifyListeners();
    return id;
  }
}

class RoutesTestModel extends ProxyViewModel {
  RoutesTestModel({required super.proxy, required super.native});
  @override
  Future<void> initialize() async {}
}

class ImportRulesModel extends ProxyViewModel {
  ImportRulesModel({required super.proxy, required super.native});
  @override
  Future<String?> readRulesFile() async => '# 导入分组\nimport.example\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RulesKernel kernel;
  late ProxyViewModel model;
  setUp(() {
    kernel = RulesKernel()
      ..defaultConnectionId = 'default'
      ..publish(
        ProxyProfile(rules: '# 网站\nexample.com\n\n# 内网\n192.168.1.0/24'),
        1,
      );
    model = RoutesTestModel(
      proxy: kernel,
      native: TestDesktop(Directory.systemTemp),
    )..loading = false;
    model.accept(kernel.appliedProfile!);
  });
  tearDown(() => model.dispose());

  test('独立应用与放弃直连草稿不提交其他配置，快捷键调用同一动作', () async {
    model.fields['port']!.text = '8888';
    model.fields['password']!.text = '草稿密码';
    model.connectionName.text = '草稿名称';
    model.changed('');
    model.editRules('new.example');
    model.page = 2;
    await model.handleNativeCall(const MethodCall('applyConfiguration'));
    expect(kernel.ruleWrites, ['new.example']);
    expect(kernel.writes, isEmpty);
    expect(kernel.appliedProfile!.values['port'], '8080');
    expect(model.fields['port']!.text, '8888');
    expect(model.fields['password']!.text, '草稿密码');
    expect(model.connectionName.text, '草稿名称');
    expect(model.rulesDirty, isFalse);
    expect(model.dirty, isTrue);
    expect(model.baseRevision, 2);
    model.editRules('other.example');
    model.discardRules();
    expect(model.rules.text, 'new.example');
    expect(model.fields['port']!.text, '8888');
    expect(model.dirty, isTrue);
  });

  test('仅修改直连规则后应用或放弃能清除脏状态', () async {
    model.editRules('new.example');
    await model.applyRules();
    expect(model.dirty, isFalse);
    model.editRules('draft.example');
    model.discardRules();
    expect(model.dirty, isFalse);
  });

  test('应用失败保留草稿，版本冲突阻止再次写入直到显式重读', () async {
    model.editRules('draft.example');
    kernel.failRules = true;
    await model.applyRules();
    expect(model.rules.text, 'draft.example');
    expect(model.rulesError, contains('规则写入失败'));
    expect(model.baseRevision, 1);
    kernel.failRules = false;
    kernel.conflictRules = true;
    await model.applyRules();
    expect(model.rules.text, 'draft.example');
    expect(model.routesConflict, isTrue);
    expect(model.baseRevision, 1);
    await model.applyRules();
    expect(kernel.ruleWrites, isEmpty);
    await model.reload();
    expect(model.rules.text, 'external.example');
    expect(model.routesConflict, isFalse);
  });

  test('外部配置更新保留未应用规则，旧查询不会被标为当前结果', () async {
    await model.queryRoute('example.com:443');
    expect(model.routeQueryStale, isFalse);
    model.editRules('draft.example');
    kernel.publish(kernel.copyProfile()..rules = 'new.example', 2);
    expect(model.rules.text, 'draft.example');
    expect(model.routesConflict, isTrue);
    expect(model.routeQueryStale, isTrue);
  });

  test('冲突后放弃全部草稿恢复最新快照，不将旧配置标记为新版本', () async {
    model.editRules('draft.example');
    kernel.publish(kernel.copyProfile()..rules = 'latest.example', 2);
    expect(model.routesConflict, isTrue);
    model.discardDrafts();
    expect(model.rules.text, 'latest.example');
    expect(model.baseRevision, 2);
    expect(model.routesConflict, isFalse);
    expect(model.dirty, isFalse);
  });

  test('列表解析、编辑与删除保留其他注释、空行和 IPv6', () {
    const text = '# 组\nexample.com # 网站\n\n# 内网\n::1/128\n';
    final entries = DirectRuleEntry.parse(text);
    expect(entries.length, 2);
    expect(entries.first.note, '网站');
    expect(entries.last.line, 4);
    expect(entries.last.scope, 'IP 网段');
    expect(
      DirectRuleEntry.replace(text, 1, 'new.example # 新备注'),
      '# 组\nnew.example # 新备注\n\n# 内网\n::1/128\n',
    );
    expect(
      DirectRuleEntry.replace(text, 4, null),
      '# 组\nexample.com # 网站\n\n# 内网\n',
    );
    expect(DirectRuleEntry.authority('2001:db8::1'), '[2001:db8::1]:443');
  });

  Future<void> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    TargetPlatform platform = TargetPlatform.macOS,
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(brightness).copyWith(platform: platform),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(1000, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: RoutesPage(model: model),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('切换模式期间按钮和底栏稳定，阻止重复提交，失败后恢复', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1120, 850);
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
    model.page = 2;
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('add-route'));
    final originalRect = tester.getRect(add);
    for (final mode in ['direct', 'proxy', 'rules']) {
      kernel.modeResult = Completer<void>();
      final pending = model.setRoutingMode(mode);
      await tester.pump();
      expect(model.locked, isTrue);
      expect(tester.widget<FilledButton>(add).enabled, isTrue);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '查询路由'))
            .enabled,
        isTrue,
      );
      expect(find.text('所有配置已保存'), findsOneWidget);
      expect(find.text('正在处理…'), findsNothing);
      expect(tester.getRect(add), originalRect);
      await tester.tap(add, warnIfMissed: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('route-host')), findsNothing);
      kernel.modeResult!.complete();
      await pending;
      await tester.pumpAndSettle();
      expect(model.locked, isFalse);
      expect(tester.getRect(add), originalRect);
      expect(find.textContaining('当前全局模式覆盖'), findsNothing);
    }
    kernel.modeResult = null;
    kernel.failMode = true;
    await model.setRoutingMode('direct');
    await tester.pumpAndSettle();
    expect(model.routingModeChanging, isFalse);
    expect(model.locked, isFalse);
    expect(kernel.routingMode, 'rules');
    expect(find.text('模式切换失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('添加直连规则保留草稿，批量与列表切换不改原文，应用才写入', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('add-route')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('route-host')),
      'work.example',
    );
    await tester.enterText(find.byKey(const ValueKey('route-note')), '工作');
    await tester.ensureVisible(find.byKey(const ValueKey('save-route')));
    await tester.tap(find.byKey(const ValueKey('save-route')));
    await tester.pumpAndSettle();
    expect(kernel.ruleWrites, isEmpty);
    expect(model.rules.text, contains('work.example # 工作'));
    final draft = model.rules.text;
    await tester.ensureVisible(find.text('批量编辑'));
    await tester.tap(find.text('批量编辑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rules-editor')), findsOneWidget);
    await tester.tap(find.text('返回列表'));
    await tester.pumpAndSettle();
    expect(model.rules.text, draft);
    await tester.tap(find.byKey(const ValueKey('apply-rules')));
    await tester.pumpAndSettle();
    expect(kernel.ruleWrites, [draft]);
    expect(model.rulesDirty, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则搜索显示匹配数量，清空后恢复列表且不修改草稿', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    final original = model.rules.text;
    await tester.enterText(find.byKey(const ValueKey('route-search')), '内网');
    await tester.pumpAndSettle();
    expect(find.text('找到 1 / 2 条规则'), findsOneWidget);
    expect(find.text('192.168.1.0/24'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
    await tester.tap(find.byTooltip('清空规则搜索'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(model.rules.text, original);
    expect(kernel.ruleWrites, isEmpty);
  });

  testWidgets('规则条目滚动到边界时不拉伸回弹或产生出现位移', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    model.editRules(List.generate(80, (i) => 'route-$i.example').join('\n'));
    await mount(tester);
    final scrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey('routes')),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = tester.getRect(find.text('route-0.example'));
    await tester.drag(scrollable, const Offset(0, 120));
    await tester.pump();
    expect(position.pixels, 0, reason: '条目在边界保持静止，不播放滚动回弹');
    expect(tester.getRect(find.text('route-0.example')), before);
    await tester.pumpAndSettle();
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final targets in [false, true]) {
      testWidgets('滚入视野的规则标题首帧完整，不继承列表位置：$platform / 指定目标=$targets', (
        tester,
      ) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final profile = kernel.copyProfile()
          ..rules = List.generate(
            150,
            (i) => 'route-$i.example # 中文备注',
          ).join('\n')
          ..routesOverrides = List.generate(
            150,
            (i) => 'proxy target-$i.example',
          ).join('\n');
        kernel.publish(profile, 2);
        model.accept(profile);
        await mount(
          tester,
          platform: platform,
          brightness: targets ? Brightness.dark : Brightness.light,
          scale: targets ? 1.3 : 1,
        );
        if (targets) {
          await tester.tap(find.text('指定目标 150'));
          await tester.pumpAndSettle();
        }
        final list = find.byKey(const PageStorageKey('routes'));
        final outer = find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(outer).position;
        for (final offset in [700.0, 1500.0, 2300.0, 700.0]) {
          position.jumpTo(offset);
          await tester.pump();
          final titles = find.descendant(
            of: list,
            matching: find.byType(SelectableText),
          );
          expect(titles, findsWidgets);
          for (final delay in [
            Duration.zero,
            const Duration(milliseconds: 16),
            const Duration(milliseconds: 200),
          ]) {
            if (delay != Duration.zero) await tester.pump(delay);
            for (final title in titles.evaluate()) {
              final editor = find.descendant(
                of: find.byWidget(title.widget),
                matching: find.byType(EditableText),
              );
              final editable = tester
                  .state<EditableTextState>(editor)
                  .renderEditable;
              expect(
                editable.offset.pixels,
                0,
                reason:
                    '${(title.widget as SelectableText).data} 首帧及后续帧不得继承外层偏移',
              );
              expect(
                editable
                    .getLocalRectForCaret(const TextPosition(offset: 0))
                    .top,
                greaterThanOrEqualTo(0),
                reason: '标题顶部不能在自己的文字区域内被裁切',
              );
            }
          }
          expect(position.pixels, offset, reason: '修复标题不能改变用户的列表位置');
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('指定目标列表启用时首帧即显示最终状态，不逐项淡入', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    kernel.publish(
      kernel.copyProfile()..routesOverrides = 'proxy api.example.com',
      1,
    );
    await mount(tester);
    await tester.tap(find.text('指定目标 1'));
    await tester.pumpAndSettle();
    kernel.connected = false;
    kernel.notifyListeners();
    await tester.pumpAndSettle();
    final remove = find.text('移除指定');
    Color? color() =>
        tester.renderObject<RenderParagraph>(remove).text.style!.color;
    final disabledColor = color();
    final before = tester.getRect(find.text('api.example.com'));
    kernel.connected = true;
    kernel.notifyListeners();
    await tester.pump();
    final firstColor = color();
    expect(firstColor, isNot(disabledColor));
    await tester.pump(const Duration(milliseconds: 250));
    expect(color(), firstColor);
    expect(tester.getRect(find.text('api.example.com')), before);
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [true, false]) {
    testWidgets('直连规则校验期间${cancel ? '取消' : '修改目标'}后不应用旧表单', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      final original = model.rules.text;
      await tester.tap(find.byKey(const ValueKey('add-route')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('route-host')),
        'old.example',
      );
      kernel.validationResult = Completer<void>();
      await tester.ensureVisible(find.byKey(const ValueKey('save-route')));
      await tester.tap(find.byKey(const ValueKey('save-route')));
      await tester.pump();
      expect(model.showBlockingProgress, isTrue);
      // 页面遮挡指针时，已启用控件仍可通过键盘获取焦点。
      final focus = cancel
          ? Focus.of(tester.element(find.text('取消')))
          : tester
                .widget<TextField>(find.byKey(const ValueKey('route-host')))
                .focusNode!;
      for (var step = 0; step < 20 && !focus.hasFocus; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focus.hasFocus, isTrue);
      if (cancel) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byKey(const ValueKey('route-host')), findsNothing);
      } else {
        tester.testTextInput.enterText('new.example');
      }
      await tester.pump();
      kernel.validationResult!.complete();
      await tester.pumpAndSettle();
      expect(model.rules.text, original);
      expect(kernel.ruleWrites, isEmpty);
      if (!cancel) {
        expect(find.byKey(const ValueKey('route-host')), findsOneWidget);
        kernel.validationResult = null;
        await tester.ensureVisible(find.byKey(const ValueKey('save-route')));
        await tester.tap(find.byKey(const ValueKey('save-route')));
        await tester.pumpAndSettle();
        expect(model.rules.text, contains('new.example'));
        expect(model.rules.text, isNot(contains('old.example')));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('导入预览取消不改草稿，追加只进入草稿且保留已有注释', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    model.dispose();
    kernel = RulesKernel()
      ..publish(ProxyProfile(rules: '# 原有分组\nexample.com'), 1);
    model = ImportRulesModel(
      proxy: kernel,
      native: TestDesktop(Directory.systemTemp),
    )..loading = false;
    model.accept(kernel.appliedProfile!);
    final original = model.rules.text;
    await mount(tester);
    await tester.tap(find.text('导入直连文本'));
    await tester.pumpAndSettle();
    expect(find.text('导入直连列表'), findsOneWidget);
    expect(model.rules.text, original);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.rules.text, original);
    await tester.tap(find.text('导入直连文本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追加到草稿'));
    await tester.pumpAndSettle();
    expect(model.rules.text, '$original\n\n# 导入分组\nimport.example\n');
    expect(kernel.ruleWrites, isEmpty);
    expect(model.rulesDirty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('指定目标常驻可新增和移除，查询只展示内核结果', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('route-query')),
      'api.example.com',
    );
    await tester.tap(find.text('查询路由'));
    await tester.pumpAndSettle();
    expect(find.text('直接连接 · 命中域名或地址直连规则'), findsOneWidget);
    await tester.tap(find.text('指定目标 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-route')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('route-host')),
      'api.example.com',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('save-route')));
    await tester.tap(find.byKey(const ValueKey('save-route')));
    await tester.pumpAndSettle();
    expect(kernel.targetWrites, [('api.example.com:443', 'proxy')]);
    expect(find.text('配置或内核状态已变化，请重新查询。'), findsOneWidget);
    await tester.ensureVisible(find.text('查询路由'));
    await tester.tap(find.text('查询路由'));
    await tester.pumpAndSettle();
    expect(find.text('通过代理 · 命中精确目标规则，优先于直连规则'), findsOneWidget);
    await tester.ensureVisible(find.text('移除指定'));
    await tester.tap(find.text('移除指定'));
    await tester.pumpAndSettle();
    expect(kernel.appliedProfile!.targetRoutes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('路由页小窗口及放大文字无溢出 $platform $brightness', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(
          tester,
          brightness: brightness,
          platform: platform,
          scale: 1.3,
        );
        tester.view.physicalSize = const Size(510, 420);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('批量编辑'));
        await tester.tap(find.text('批量编辑'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(const ValueKey('apply-rules'))).bottom,
          lessThanOrEqualTo(420),
        );
      });
    }
  }

  testWidgets('按需导出路由页面明暗预览', (tester) async {
    final destination = Platform.environment['UI_ROUTES_PREVIEW_DIR']!;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      for (final entry in {
        'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
        'RobotoMono': 'assets/fonts/RobotoMono-Variable.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
    });
    final systemFont = Platform.environment['UI_PREVIEW_LATIN_FONT'];
    if (systemFont != null) {
      await tester.runAsync(() async {
        await (FontLoader(DesktopDesign.fontFamily)..addFont(
              File(systemFont).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
    }
    final boundary = GlobalKey();
    Future<void> capture(String name) => tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final data = await image.toByteData(format: painting.ImageByteFormat.png);
      await Directory(destination).create(recursive: true);
      await File('$destination/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    for (final brightness in Brightness.values) {
      tester.view.physicalSize = const Size(850, 680);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(brightness),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: RoutesPage(model: model),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture('routes-${brightness.name}');
      model.editRules(
        List.generate(100, (i) => 'route-$i.example # 规则备注').join('\n'),
      );
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('routes')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(700);
      await tester.pump();
      await capture('routes-${brightness.name}-scrolled-first');
      await tester.pump(const Duration(milliseconds: 200));
      await capture('routes-${brightness.name}-scrolled-later');
      expect(tester.takeException(), isNull);
    }
  }, skip: Platform.environment['UI_ROUTES_PREVIEW_DIR'] == null);
}
