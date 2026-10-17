import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/models/traffic_summary.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/configuration_page.dart';
import 'package:network_ui/ui/pages/diagnostics_page.dart';
import 'package:network_ui/ui/pages/overview_page.dart';
import 'package:network_ui/ui/pages/routes_page.dart';
import 'package:network_ui/ui/widgets/desktop_widgets.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'traffic_summary_test.dart' show fixture;
import 'view_model_test.dart' show TestDesktop, TestKernel;

class _Kernel extends TestKernel {
  final jobs = <String, DiagnosticOperation>{};
  @override
  Map<String, DiagnosticOperation> get operations => jobs;
  @override
  DiagnosticOperation? overviewOperation(String kind) => jobs[kind];
  @override
  Future<String> resolveRoute(String target) async {
    jobs['route-query'] = DiagnosticOperation.fromJson({
      'id': 'route-query',
      'state': 'succeeded',
      'stage': 'routing',
      'elapsedMillis': 1,
      'result': {'action': 'direct', 'matchedBy': 'direct_rule'},
    });
    return 'route-query';
  }

  @override
  Future<TrafficSummary> trafficSummary({bool hourly = true}) async =>
      fixture(hourly: hourly);
}

void main() {
  late _Kernel kernel;
  late ProxyViewModel model;
  setUp(() {
    kernel = _Kernel()
      ..publish(
        ProxyProfile(
          values: {'server.host': 'proxy.example'},
          rules: List.generate(100, (i) => 'rule-$i.example').join('\n'),
        ),
        1,
      );
    model = ProxyViewModel(
      proxy: kernel,
      native: TestDesktop(Directory.systemTemp),
    )..loading = false;
    model.accept(kernel.appliedProfile!);
  });
  tearDown(() => model.dispose());

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      // 保留真实 PageStorageBucket，模拟页面卸载后恢复非零滚动位置。
      Future<void> mount(
        WidgetTester tester,
        Widget child,
        PageStorageBucket bucket,
      ) => tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(brightness).copyWith(platform: platform),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  brightness == Brightness.dark ? 1.3 : 1,
                ),
              ),
              child: PageStorage(
                bucket: bucket,
                child: Scaffold(body: child),
              ),
            ),
          ),
        ),
      );

      ScrollPosition position(WidgetTester tester, String key) => tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(PageStorageKey(key)),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;

      void checkText(WidgetTester tester, Finder area) {
        final editors = find.descendant(
          of: area,
          matching: find.byType(EditableText, skipOffstage: false),
          skipOffstage: false,
        );
        expect(editors, findsWidgets);
        for (final editor in editors.evaluate()) {
          final text = editor.widget as EditableText;
          final render = tester
              .state<EditableTextState>(
                find.byWidget(text, skipOffstage: false),
              )
              .renderEditable;
          if ((render.offset as ScrollPosition).maxScrollExtent == 0) {
            expect(
              render.offset.pixels,
              0,
              reason: '无需内部滚动的文字不应读取页面偏移：${text.controller.text}',
            );
            // 检查实际文字区域，光标矩形的物理像素对齐不代表文字被裁切。
            for (final box in render.getBoxesForSelection(
              TextSelection(
                baseOffset: 0,
                extentOffset: text.controller.text.length,
              ),
            )) {
              expect(box.top, greaterThanOrEqualTo(0), reason: '文字顶部不能被自身视口裁切');
            }
          }
        }
      }

      Future<void> checkStableText(WidgetTester tester, Finder area) async {
        checkText(tester, area);
        for (final delay in [
          const Duration(milliseconds: 16),
          const Duration(milliseconds: 200),
        ]) {
          await tester.pump(delay);
          checkText(tester, area);
        }
      }

      testWidgets('概览地址和出口文字恢复首帧不被页面滚动位置裁切：$platform/$brightness', (
        tester,
      ) async {
        kernel.jobs['exit-ip'] = DiagnosticOperation.fromJson({
          'id': 'exit',
          'state': 'succeeded',
          'stage': 'exit-ip',
          'elapsedMillis': 1,
          'result': {'ip': '203.0.113.24'},
        });
        final bucket = PageStorageBucket();
        await mount(tester, OverviewPage(model: model), bucket);
        await tester.pumpAndSettle();
        position(tester, 'overview').jumpTo(180);
        await tester.pumpAndSettle();
        await mount(tester, const SizedBox(), bucket);
        await mount(tester, OverviewPage(model: model), bucket);
        expect(position(tester, 'overview').pixels, 180);
        await checkStableText(tester, find.byType(OverviewPage));
      });

      testWidgets('诊断结果滚入视野时不继承父列表偏移：$platform/$brightness', (tester) async {
        for (var i = 0; i < 60; i++) {
          kernel.jobs['job-$i'] = DiagnosticOperation.fromJson({
            'id': 'job-$i',
            'state': 'failed',
            'stage': 'dns',
            'elapsedMillis': i,
            'result': {'code': 'TEST', 'message': '目标 $i 查询失败'},
          });
        }
        await mount(tester, DiagnosticsPage(model: model), PageStorageBucket());
        await tester.pumpAndSettle();
        position(tester, 'diagnostics').jumpTo(900);
        await tester.pump();
        await checkStableText(tester, find.byType(DiagnosticsPage));
      });

      testWidgets('恢复路由页后搜索和查询输入首帧不读取列表位置：$platform/$brightness', (
        tester,
      ) async {
        final bucket = PageStorageBucket();
        await mount(tester, RoutesPage(model: model), bucket);
        await tester.pumpAndSettle();
        position(tester, 'routes').jumpTo(150);
        await tester.pumpAndSettle();
        await mount(tester, const SizedBox(), bucket);
        await mount(tester, RoutesPage(model: model), bucket);
        expect(position(tester, 'routes').pixels, 150);
        await checkStableText(tester, find.byType(RoutesPage));
      });

      testWidgets('恢复连接配置后筛选输入首帧不读取页面位置：$platform/$brightness', (tester) async {
        tester.view.physicalSize = const Size(620, 440);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bucket = PageStorageBucket();
        await mount(tester, ConfigurationPage(model: model), bucket);
        await tester.pumpAndSettle();
        position(tester, 'configuration').jumpTo(80);
        await tester.pumpAndSettle();
        final saved = position(tester, 'configuration').pixels;
        expect(saved, greaterThan(0));
        await mount(tester, const SizedBox(), bucket);
        await mount(tester, ConfigurationPage(model: model), bucket);
        expect(position(tester, 'configuration').pixels, saved);
        await checkStableText(tester, find.byType(ConfigurationPage));
      });

      testWidgets('批量规则编辑保留自己的滚动位置，不继承外层列表偏移：$platform/$brightness', (
        tester,
      ) async {
        await mount(tester, RoutesPage(model: model), PageStorageBucket());
        await tester.pumpAndSettle();
        position(tester, 'routes').jumpTo(100);
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量编辑'));
        await tester.pump();
        ScrollPosition editorPosition() =>
            tester
                    .state<EditableTextState>(
                      find.descendant(
                        of: find.byKey(const ValueKey('rules-editor')),
                        matching: find.byType(EditableText),
                      ),
                    )
                    .renderEditable
                    .offset
                as ScrollPosition;
        expect(editorPosition().pixels, 0);
        editorPosition().jumpTo(240);
        await tester.pumpAndSettle();
        await tester.tap(find.text('返回列表'));
        await tester.pumpAndSettle();
        position(tester, 'routes').jumpTo(80);
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量编辑'));
        await tester.pump();
        expect(editorPosition().pixels, 240, reason: '文档自己的位置应独立保留');
        expect(model.rules.text, kernel.appliedProfile!.rules);
        expect(tester.takeException(), isNull);
      });

      testWidgets('从列表深处编辑规则及接收查询结果时文字首帧不滑出：$platform/$brightness', (
        tester,
      ) async {
        await mount(tester, RoutesPage(model: model), PageStorageBucket());
        await tester.pumpAndSettle();
        position(tester, 'routes').jumpTo(700);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(TextButton, '编辑').hitTestable().first,
        );
        await tester.pump();
        await checkStableText(tester, find.byType(RoutesPage));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        position(tester, 'routes').jumpTo(700);
        await tester.pumpAndSettle();
        await model.queryRoute('example.com:443');
        await tester.pump();
        await checkStableText(tester, find.byType(RoutesPage));
        expect(model.routeQuery?.result.action, 'direct');
        expect(model.routeQueryStale, isFalse);
        expect(
          find.byKey(
            const PageStorageKey('route-query-result'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('共用空状态首次显示时不读取宿主页滚动位置：$platform/$brightness', (tester) async {
        var empty = false;
        Widget page() => Builder(
          builder: (context) {
            final ui = DesktopWidgets(context, model);
            return ui.list('empty-host', [
              const SizedBox(height: 800),
              if (empty)
                ui.empty(Icons.search, '没有匹配结果', '尝试调整筛选')
              else
                const SizedBox(height: 350),
            ]);
          },
        );
        final bucket = PageStorageBucket();
        await mount(tester, page(), bucket);
        await tester.pumpAndSettle();
        position(tester, 'empty-host').jumpTo(700);
        await tester.pumpAndSettle();
        empty = true;
        await mount(tester, page(), bucket);
        final inner = find.byType(SingleChildScrollView);
        expect(inner, findsOneWidget);
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(of: inner, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        expect(scroll.pixels, 0, reason: '空状态内容应从顶部完整显示');
      });
    }
  }
}
