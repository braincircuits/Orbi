import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/access_records_page.dart';

import 'traffic_fixture.dart';

class HistoryKernel extends ProxyController {
  final requests = <(String, int?)>[];
  bool fail = false;
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    int? beforeId,
  }) async {
    requests.add((target, beforeId));
    if (fail) throw StateError('测试数据库不可用');
    return AccessRecordPage.fromJson({
      'items': [
        {
          'id': beforeId == null ? 20 : 10,
          'createdAt': 1791716489000,
          'target': beforeId == null ? 'example.com:443' : 'earlier.example:80',
          'source': '127.0.0.1:8081',
          'method': 'CONNECT',
          'route': 'proxy',
          'protocol': 'http2',
          'profileName': '默认连接',
          'state': 'connected',
        },
      ],
      'nextBeforeId': beforeId == null ? 20 : 0,
    });
  }

  @override
  Future<TrafficRecordPage> trafficHistory({
    int? from,
    int? to,
    int? beforeId,
  }) async => TrafficRecordPage.fromJson({
    'items': [
      {...trafficFixture(time: 300000), 'id': 1},
    ],
    'nextBeforeId': 0,
    'hasMore': false,
  });
}

void main() {
  test('历史流量跨启动会话及采样空档翻页不跳过旧记录', () {
    final page = TrafficRecordPage.fromJson({
      'items': [
        {...trafficFixture(time: 600000), 'id': 9, 'sessionId': 'new'},
        {...trafficFixture(time: 500000), 'id': 8, 'sessionId': 'new'},
        {...trafficFixture(time: 200000), 'id': 7, 'sessionId': 'old'},
      ],
      'nextBeforeId': 0,
      'hasMore': false,
    });
    expect(page.traffic!.history, hasLength(2));
    expect(page.nextBeforeId, 8);
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
    await tester.tap(find.text('加载更早记录'));
    await tester.pumpAndSettle();
    expect(kernel.requests.last, ('', 20));
    expect(find.text('earlier.example:80'), findsOneWidget);
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
    expect(kernel.requests.last, ('example', null));
    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('earlier.example:80'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
