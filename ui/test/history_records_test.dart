import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/access_records_page.dart';
import 'package:network_ui/ui/widgets/sortable_table.dart';

class HistoryKernel extends ProxyController {
  final requests = <(String, int?, bool, String)>[];
  bool fail = false;
  final directions = <bool>[];
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) async {
    requests.add((target, beforeValue, failedOnly, order));
    directions.add(ascending);
    if (fail) throw StateError('测试数据库不可用');
    return AccessRecordPage.fromJson({
      'items': [
        {
          'host': beforeValue == null ? 'example.com' : 'earlier.example',
          'connectionCount': 123,
          'lastAccessAt': 1791716489000,
          'lastFailureAt': failedOnly ? 1791716400000 : 0,
        },
      ],
      'hasMore': beforeValue == null,
      'nextValue': beforeValue == null ? 20 : 0,
      'nextHost': beforeValue == null ? 'example.com' : '',
    });
  }
}

class PagedHistoryKernel extends HistoryKernel {
  final pending = <Completer<AccessRecordPage>>[];
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) {
    requests.add((target, beforeValue, failedOnly, order));
    directions.add(ascending);
    final result = Completer<AccessRecordPage>();
    pending.add(result);
    return result.future;
  }

  void completePage(int index, int next) => pending[index].complete(
    AccessRecordPage.fromJson({
      'items': List.generate(
        20,
        (i) => {
          'host': 'page-$index-item-$i.example',
          'connectionCount': 100 - i,
          'lastAccessAt': 1791716489000,
          'lastFailureAt': 0,
        },
      ),
      'hasMore': next != 0,
      'nextValue': next,
      'nextHost': next != 0 ? 'page-$index-item-19.example' : '',
    }),
  );
}

class LargeHistoryKernel extends HistoryKernel {
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) async => AccessRecordPage.fromJson({
    'items': List.generate(
      5000,
      (index) => {
        'host': 'record-${index.toString().padLeft(5, '0')}.example',
        'connectionCount': index + 1,
        'lastAccessAt': 1791716489000,
        'lastFailureAt': 0,
      },
    ),
    'hasMore': false,
    'nextValue': 0,
    'nextHost': '',
  });
}

void main() {
  testWidgets('5000 条访问记录滚动跳到底部仅构建可见行', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = LargeHistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light)
            .copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
      ),
    );
    await tester.pumpAndSettle();
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is TableText) builds++;
      previous?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const PageStorageKey('access-records')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    final elapsed = Stopwatch()..start();
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    elapsed.stop();
    debugPrint(
      '访问记录跳到底部：5000 行，构建 $builds 个单元格，测试耗时 ${elapsed.elapsedMilliseconds} 毫秒',
    );
    expect(find.text('record-04999.example').hitTestable(), findsOneWidget);
    expect(builds, lessThan(200), reason: '滚动跳跃不能逐行构建中间的几千条记录');
    position.jumpTo(0);
    await tester.pumpAndSettle();
    builds = 0;
    final controller = tester
        .widget<ListView>(find.byKey(const PageStorageKey('access-records')))
        .controller;
    final scrollbar = find.byWidgetPredicate(
      (widget) => widget is Scrollbar && widget.controller == controller,
    );
    final bounds = tester.getRect(scrollbar);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(Offset(bounds.right - 4, bounds.top + 12));
    await mouse.moveTo(Offset(bounds.right - 4, bounds.top + 52));
    await tester.pump();
    await mouse.moveTo(Offset(bounds.right - 4, bounds.bottom - 24));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(position.maxScrollExtent * .8));
    expect(builds, lessThan(200), reason: '鼠标拖动滚动条也只能构建可见行');
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分页集合去重保留顺序，刷新和内核切换不会误删相同域名', (tester) async {
    final kernel = PagedHistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    Widget page() => MaterialApp(
      theme: desktopTheme(Brightness.light),
      home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
    );
    await tester.pumpWidget(page());
    kernel.completePage(0, 81);
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const PageStorageKey('access-records')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    AccessRecordPage values(List<String> hosts) => AccessRecordPage.fromJson({
      'items': [
        for (final host in hosts)
          {
            'host': host,
            'connectionCount': 1,
            'lastAccessAt': 1791716489000,
            'lastFailureAt': 0,
          },
      ],
      'hasMore': false,
      'nextValue': 0,
      'nextHost': '',
    });
    kernel.pending[1].complete(
      values([
        'page-0-item-19.example',
        'new-a.example',
        'new-a.example',
        'new-b.example',
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已显示 22 个域名 / IP'), findsOneWidget);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('new-a.example')).dy,
      lessThan(tester.getTopLeft(find.text('new-b.example')).dy),
    );
    await tester.tap(find.text('查询 / 刷新'));
    await tester.pump();
    kernel.pending[2].complete(values(['new-a.example']));
    await tester.pumpAndSettle();
    expect(find.textContaining('已显示 1 个域名 / IP'), findsOneWidget);
    expect(find.text('new-a.example'), findsOneWidget);
    kernel.kernelGeneration++;
    await tester.pumpWidget(page());
    await tester.pump();
    kernel.pending[3].complete(values(['new-a.example']));
    await tester.pumpAndSettle();
    expect(find.text('new-a.example'), findsOneWidget);
    expect(find.textContaining('已显示 1 个域名 / IP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('访问记录行高随文字缩放，远处行无裁切：$scale', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final kernel = LargeHistoryKernel()..connected = true;
      addTearDown(kernel.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(Brightness.dark),
          home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const PageStorageKey('access-records')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final text = find.text('record-04999.example');
      expect(text, findsOneWidget);
      final row = find
          .ancestor(of: text, matching: find.byType(Container))
          .first;
      final textBounds = tester.getRect(text), rowBounds = tester.getRect(row);
      expect(textBounds.top, greaterThanOrEqualTo(rowBounds.top));
      expect(textBounds.bottom, lessThanOrEqualTo(rowBounds.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('刷新保留记录和布局，阻止重复请求，失败保留结果并可重试', (tester) async {
    final kernel = PagedHistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
      ),
    );
    kernel.completePage(0, 0);
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('access-record-list'));
    final refresh = find.widgetWithText(OutlinedButton, '查询 / 刷新');
    final bounds = tester.getRect(list);
    final row = find.text('page-0-item-0.example');
    final rowPosition = tester.getTopLeft(row);
    final count = find.textContaining('已显示 20 个域名 / IP');

    await tester.tap(refresh);
    await tester.pump();
    expect(find.text('正在加载访问记录…'), findsNothing);
    expect(count, findsOneWidget);
    expect(tester.getRect(list), bounds);
    expect(tester.getTopLeft(row), rowPosition);
    expect(tester.widget<OutlinedButton>(refresh).onPressed, isNotNull);
    await tester.tap(refresh);
    await tester.pump();
    expect(kernel.requests.length, 2);

    kernel.completePage(1, 0);
    await tester.pumpAndSettle();
    expect(tester.getRect(list), bounds);
    expect(row, findsNothing);
    expect(find.text('page-1-item-0.example'), findsOneWidget);
    expect(count, findsOneWidget);

    await tester.tap(refresh);
    await tester.pump();
    kernel.pending[2].completeError(StateError('测试刷新失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试刷新失败'), findsOneWidget);
    expect(find.text('page-1-item-0.example'), findsOneWidget);
    expect(count, findsOneWidget);
    await tester.tap(refresh);
    await tester.pump();
    kernel.completePage(3, 0);
    await tester.pumpAndSettle();
    expect(find.textContaining('测试刷新失败'), findsNothing);
    expect(find.text('page-3-item-0.example'), findsOneWidget);
    expect(find.text('page-1-item-0.example'), findsNothing);
    expect(tester.getRect(list), bounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('访问表格每列双向查询，切换排序丢弃旧分页响应', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final kernel = PagedHistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
      ),
    );
    kernel.completePage(0, 81);
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const PageStorageKey('access-records')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(kernel.requests.length, 2);
    await tester.tap(find.widgetWithText(TextButton, '域名 / IP'));
    await tester.pump();
    expect(kernel.requests.last, ('', null, false, 'host'));
    kernel.completePage(2, 0);
    await tester.pumpAndSettle();
    kernel.completePage(1, 50);
    await tester.pumpAndSettle();
    expect(find.text('page-1-item-0.example'), findsNothing);
    expect(find.text('page-2-item-0.example'), findsOneWidget);
    for (final (label, order) in [
      ('域名 / IP', 'host'),
      ('连接次数', 'count'),
      ('最后访问时间', 'recent'),
      ('最后失败时间', 'failure'),
    ]) {
      // 域名列已切为升序，再点击两次验证来回切换。
      for (final ascending in order == 'host' ? [false, true] : [true, false]) {
        await tester.tap(find.widgetWithText(TextButton, label));
        await tester.pump();
        expect(kernel.requests.last, ('', null, false, order));
        expect(kernel.directions.last, ascending);
        kernel.completePage(kernel.pending.length - 1, 0);
        await tester.pumpAndSettle();
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动自动分页防重入，失败不循环请求，重试后到末页停止', (tester) async {
    final kernel = PagedHistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: AccessRecordsPage(proxy: kernel)),
      ),
    );
    kernel.completePage(0, 81);
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const PageStorageKey('access-records')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(kernel.requests, [
      ('', null, false, 'recent'),
      ('', 81, false, 'recent'),
    ]);
    position.jumpTo(position.maxScrollExtent - 5);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(kernel.requests.length, 2);
    kernel.pending[1].completeError(StateError('测试分页失败'));
    await tester.pumpAndSettle();
    position.jumpTo(position.maxScrollExtent - 5);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(kernel.requests.length, 2);
    expect(find.textContaining('测试分页失败'), findsOneWidget);
    await tester.tap(find.text('重试加载'));
    await tester.pump();
    expect(kernel.requests.last, ('', 81, false, 'recent'));
    kernel.completePage(2, 0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('page-2-item-19.example'),
      400,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('access-records')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(kernel.requests.length, 3);
    expect(find.text('page-2-item-19.example'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('访问记录分页、查询、失败恢复和窄窗口布局', (tester) async {
    final kernel = HistoryKernel()..connected = true;
    addTearDown(kernel.dispose);
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.dark),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: AccessRecordsPage(proxy: kernel),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('123'), findsNWidgets(2));
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('加载更早记录'), findsNothing);
    expect(find.textContaining('默认连接'), findsNothing);
    expect(kernel.requests.last, ('', 20, false, 'recent'));
    expect(find.text('earlier.example'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('access-search')),
      'example',
    );
    kernel.fail = true;
    await tester.tap(find.text('查询 / 刷新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试数据库不可用'), findsOneWidget);
    kernel.fail = false;
    await tester.tap(find.text('查询 / 刷新'));
    await tester.pumpAndSettle();
    expect(kernel.requests.sublist(kernel.requests.length - 2), [
      ('example', null, false, 'recent'),
      ('example', 20, false, 'recent'),
    ]);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('earlier.example'), findsOneWidget);
    await tester.tap(find.text('全部域名'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '曾经失败'));
    await tester.pumpAndSettle();
    expect(kernel.requests.sublist(kernel.requests.length - 2), [
      ('example', null, true, 'recent'),
      ('example', 20, true, 'recent'),
    ]);
    expect(kernel.requests.last, ('example', 20, true, 'recent'));
    await tester.tap(find.byKey(const ValueKey('access-state-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '全部域名'));
    await tester.pumpAndSettle();
    expect(kernel.requests.sublist(kernel.requests.length - 2), [
      ('example', null, false, 'recent'),
      ('example', 20, false, 'recent'),
    ]);
    expect(find.text('earlier.example'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(TextButton, '连接次数'));
    await tester.tap(find.widgetWithText(TextButton, '连接次数'));
    await tester.pumpAndSettle();
    expect(kernel.requests.last, ('example', 20, false, 'count'));
    expect(tester.takeException(), isNull);
  });
}
