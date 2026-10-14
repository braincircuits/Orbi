import 'package:network_ui/ui/traffic_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/traffic_chart.dart';

import 'traffic_fixture.dart';
import 'traffic_summary_test.dart' show SummaryKernel;

void main() {
  test('实时快照去重、拒绝旧采样并按启动会话重置', () {
    final first = TrafficSnapshot.merge(null, trafficFixture(time: 100000));
    expect(
      TrafficSnapshot.merge(first, trafficFixture(time: 100000)),
      same(first),
    );
    expect(
      TrafficSnapshot.merge(first, trafficFixture(time: 99000)),
      same(first),
    );
    final next = TrafficSnapshot.merge(first, trafficFixture(time: 200000));
    expect(next.current.sampledAt, 200000);
    final restarted = TrafficSnapshot.merge(
      next,
      trafficFixture(session: '新的启动', time: 300000),
    );
    expect(restarted.sessionId, '新的启动');
    expect(formatTrafficBytes(2460000), '2.46 MB');
    expect(formatTrafficBytes(128000), '128 KB');
  });
  testWidgets('分钟趋势切换范围不重复请求，离线保留数据', (tester) async {
    final kernel = SummaryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: TrafficChart(proxy: kernel)),
      ),
    );
    await tester.pumpAndSettle();
    expect(kernel.requests, [false]);
    expect(find.text('每分钟流量 · 代理与直连'), findsOneWidget);
    await tester.tap(find.text('24 小时'));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<int>>(
            find.byKey(const ValueKey('traffic-range')),
          )
          .selected,
      {24},
    );
    expect(kernel.requests, [false]);
    kernel.connected = false;
    kernel.publish();
    await tester.pump();
    expect(find.text('内核未连接，保留最近读取的分钟趋势。'), findsOneWidget);
    kernel.connected = true;
    kernel.publish();
    await tester.pumpAndSettle();
    expect(kernel.requests, [false, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
