import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/traffic_chart.dart';

import 'traffic_fixture.dart';

void main() {
  test('流量历史去重、拒绝旧采样、保持五分钟窗口并按启动会话重置', () {
    var traffic = TrafficSnapshot.merge(null, trafficFixture(time: 100000));
    expect(traffic.history.length, 61);
    traffic = TrafficSnapshot.merge(
      traffic,
      trafficFixture(time: 100000, history: false),
    );
    expect(traffic.history.length, 61);
    traffic = TrafficSnapshot.merge(
      traffic,
      trafficFixture(time: 99000, history: false),
    );
    expect(traffic.current.sampledAt, 100000);
    for (var i = 1; i <= 400; i++) {
      traffic = TrafficSnapshot.merge(
        traffic,
        trafficFixture(time: 100000 + i * 1000, history: false),
      );
    }
    expect(traffic.history.length, 301);
    expect(traffic.history.first.sampledAt, 200000);
    traffic = TrafficSnapshot.merge(
      traffic,
      trafficFixture(session: '新的启动', time: 600000, history: false),
    );
    expect(traffic.history.length, 1);
    expect(traffic.sessionId, '新的启动');
    expect(() => traffic.history.clear(), throwsUnsupportedError);
  });
  test('快照恢复断线历史，不把缺失采样伪造成零流量', () {
    final first = TrafficSnapshot.merge(
      null,
      trafficFixture(time: 100000, history: false),
    );
    final restored = TrafficSnapshot.merge(first, trafficFixture(time: 200000));
    expect(restored.history.length, 61);
    expect(restored.history.first.sampledAt, 140000);
    expect(formatTrafficBytes(2460000), '2.46 MB');
    expect(formatTrafficBytes(128000), '128 KB');
  });
  testWidgets('趋势范围、图例、悬停与离线和停止状态', (tester) async {
    var connected = true, running = true;
    final traffic = TrafficSnapshot.merge(null, trafficFixture(time: 300000));
    Future<void> pump() => tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 500,
            child: TrafficChart(
              traffic: traffic,
              connected: connected,
              running: running,
            ),
          ),
        ),
      ),
    );
    await pump();
    expect(find.text('流量趋势'), findsOneWidget);
    await tester.tap(find.text('5 分钟'));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<int>>(
            find.byKey(const ValueKey('traffic-range')),
          )
          .selected,
      {5},
    );
    await tester.tap(find.text('发送'));
    await tester.tap(find.text('接收'));
    await tester.pump();
    expect(find.text('选择发送或接收以显示曲线'), findsOneWidget);
    await tester.tap(find.text('接收'));
    await tester.pump();
    final rect = tester.getRect(find.byKey(const ValueKey('traffic-plot')));
    await tester.tapAt(Offset(rect.right - 20, rect.top + 70));
    await tester.pump();
    expect(find.text('接收 2.46 MB/s'), findsOneWidget);
    running = false;
    await pump();
    expect(find.text('服务已停止 · 保留最近记录'), findsOneWidget);
    connected = false;
    await pump();
    expect(find.text('内核未连接，流量数据不可用'), findsOneWidget);
    expect(find.text('接收 2.46 MB/s'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
