import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/access_records_page.dart';

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

void main() {
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
