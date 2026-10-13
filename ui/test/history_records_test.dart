import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/access_records_page.dart';

class HistoryKernel extends ProxyController {
  final requests = <(String, int?, String)>[];
  bool fail = false;
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    String state = '',
    int? beforeId,
  }) async {
    requests.add((target, beforeId, state));
    if (fail) throw StateError('测试数据库不可用');
    return AccessRecordPage.fromJson({
      'items': [
        {
          'id': beforeId == null ? 20 : 10,
          'createdAt': 1791716489000,
          'target': beforeId == null ? 'example.com:443' : 'earlier.example:80',
          'source': '127.0.0.1:8081',
          'method': beforeId == null ? 'CONNECT' : 'CONNECT-UDP',
          'route': 'proxy',
          'protocol': 'http2',
          'profileName': '默认连接',
          'state': state.isEmpty ? 'connected' : state,
        },
      ],
      'nextBeforeId': beforeId == null ? 20 : 0,
    });
  }
}

class PagedHistoryKernel extends HistoryKernel {
  final pending = <Completer<AccessRecordPage>>[];
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    String state = '',
    int? beforeId,
  }) {
    requests.add((target, beforeId, state));
    final result = Completer<AccessRecordPage>();
    pending.add(result);
    return result.future;
  }

  void completePage(int index, int next) => pending[index].complete(
    AccessRecordPage.fromJson({
      'items': List.generate(
        20,
        (i) => {
          'id': 100 - index * 20 - i,
          'createdAt': 1791716489000,
          'target': 'page-$index-item-$i.example:443',
          'source': '127.0.0.1:8081',
          'method': 'CONNECT',
          'route': 'proxy',
          'protocol': 'http2',
          'profileName': '测试连接',
          'state': 'failed',
        },
      ),
      'nextBeforeId': next,
    }),
  );
}

void main() {
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
    expect(kernel.requests, [('', null, ''), ('', 81, '')]);
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
    expect(kernel.requests.last, ('', 81, ''));
    kernel.completePage(2, 0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('page-2-item-19.example:443'),
      400,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('access-records')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(kernel.requests.length, 3);
    expect(find.text('page-2-item-19.example:443'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('分钟历史保留不同启动会话的增量，分页游标由内核决定', () {
    final page = TrafficRecordPage.fromJson({
      'items': [
        for (var id = 3; id >= 1; id--)
          {
            'id': id,
            'sessionId': id == 1 ? '旧会话' : '新会话',
            'minuteStart': 60000,
            'activeDurationMillis': 15000,
            'sentBytes': 100,
            'receivedBytes': 200,
          },
      ],
      'nextBeforeId': 1,
    });
    expect(page.items, hasLength(3));
    expect(page.items.last.sessionId, '旧会话');
    expect(page.items.first.activeDurationMillis, 15000);
    expect(page.nextBeforeId, 1);
    expect(() => page.items.clear(), throwsUnsupportedError);
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
    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('原始 TCP'), findsOneWidget);
    expect(find.text('CONNECT · 代理 · HTTP/2'), findsOneWidget);
    expect(find.text('加载更早记录'), findsNothing);
    expect(find.textContaining('默认连接'), findsNothing);
    expect(kernel.requests.last, ('', 20, ''));
    expect(find.text('earlier.example:80'), findsOneWidget);
    expect(find.text('原始 UDP'), findsOneWidget);
    expect(find.text('CONNECT-UDP · 代理 · HTTP/2'), findsOneWidget);
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
      ('example', null, ''),
      ('example', 20, ''),
    ]);
    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('earlier.example:80'), findsOneWidget);
    await tester.tap(find.text('全部状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '连接失败'));
    await tester.pumpAndSettle();
    expect(kernel.requests.sublist(kernel.requests.length - 2), [
      ('example', null, 'failed'),
      ('example', 20, 'failed'),
    ]);
    expect(kernel.requests.last, ('example', 20, 'failed'));
    await tester.tap(find.byKey(const ValueKey('access-state-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '全部状态'));
    await tester.pumpAndSettle();
    expect(kernel.requests.sublist(kernel.requests.length - 2), [
      ('example', null, ''),
      ('example', 20, ''),
    ]);
    expect(find.text('earlier.example:80'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
