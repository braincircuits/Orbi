import 'package:network_ui/ui/traffic_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/traffic_chart.dart';
import 'package:network_ui/ui/widgets/traffic_summary_chart.dart';

import 'traffic_fixture.dart';
import 'traffic_summary_test.dart' show SummaryKernel, fixture;

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
  testWidgets('切换内核立即清除旧趋势，迟到响应不会覆盖新实例数据', (tester) async {
    final kernel = SummaryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: TrafficChart(proxy: kernel)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TrafficSummaryChart), findsOneWidget);
    kernel.delayed = true;
    kernel.kernelGeneration++;
    kernel.publish();
    await tester.pump();
    expect(find.byType(TrafficSummaryChart), findsNothing);
    kernel.kernelGeneration++;
    kernel.publish();
    await tester.pump();
    kernel.pending[0].complete(fixture(hourly: false, sent: 123));
    await tester.pump();
    expect(find.byType(TrafficSummaryChart), findsNothing);
    kernel.pending[1].complete(fixture(hourly: false, sent: 456));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TrafficSummaryChart>(find.byType(TrafficSummaryChart))
          .summary
          .sentBytes,
      456,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('隐藏趋势不请求，恢复显示补读最新上下文并保留所选范围', (tester) async {
    final kernel = SummaryKernel()..connected = true;
    final replacement = SummaryKernel()..connected = true;
    addTearDown(kernel.dispose);
    addTearDown(replacement.dispose);
    Future<void> mount(bool visible, [SummaryKernel? proxy]) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(Brightness.light),
          home: Scaffold(
            body: TrafficChart(proxy: proxy ?? kernel, visible: visible),
          ),
        ),
      );
      await tester.pump();
    }

    await mount(false);
    kernel.kernelGeneration++;
    kernel.publish();
    await tester.pump();
    expect(kernel.requests, isEmpty);
    await mount(true);
    await tester.pumpAndSettle();
    expect(kernel.requests, [false]);
    await tester.tap(find.text('24 小时'));
    kernel.delayed = true;
    await tester.tap(find.byTooltip('刷新趋势'));
    await tester.pump();
    await mount(false, replacement);
    kernel.pending.single.complete(fixture(hourly: false, sent: 999));
    await tester.pump();
    expect(find.byType(TrafficSummaryChart), findsNothing);
    expect(replacement.requests, isEmpty);
    await mount(true, replacement);
    await tester.pumpAndSettle();
    expect(replacement.requests, [false]);
    expect(
      tester
          .widget<TrafficSummaryChart>(find.byType(TrafficSummaryChart))
          .summary
          .sentBytes,
      1000,
    );
    expect(
      tester
          .widget<SegmentedButton<int>>(
            find.byKey(const ValueKey('traffic-range')),
          )
          .selected,
      {24},
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
