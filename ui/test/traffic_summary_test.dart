import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/traffic_summary.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/traffic_history_dialog.dart';
import 'package:network_ui/ui/widgets/traffic_summary_chart.dart';

TrafficSummary fixture({
  bool hourly = true,
  bool empty = false,
  int sent = 1000,
}) {
  final step = hourly ? 3600000 : 60000;
  final count = hourly ? 720 : 1440;
  final start = DateTime.utc(2026, 9, 15).millisecondsSinceEpoch;
  return TrafficSummary.fromJson({
    'from': start,
    'to': start + count * step,
    'zoneId': 'Asia/Shanghai',
    'interval': hourly ? 'hour' : 'minute',
    'sentBytes': empty ? 0 : sent,
    'receivedBytes': empty ? 0 : 2000,
    'recordCount': empty ? 0 : 1,
    'buckets': [
      for (var i = 0; i < count; i++)
        {
          'from': start + i * step,
          'to': start + (i + 1) * step,
          'sentBytes': !empty && i == 0 ? sent : 0,
          'receivedBytes': !empty && i == 0 ? 2000 : 0,
          'recordCount': !empty && i < 2 ? 1 : 0,
          'label': '2026-09-15 ${i.toString().padLeft(2, '0')}:00 +08:00',
          'shortLabel': '09-15 ${i.toString().padLeft(2, '0')}:00',
        },
    ],
  });
}

class SummaryKernel extends ProxyController {
  final requests = <bool>[];
  final pending = <Completer<TrafficSummary>>[];
  bool fail = false, empty = false, delayed = false;
  @override
  Future<TrafficSummary> trafficSummary({bool hourly = true}) async {
    requests.add(hourly);
    if (fail) throw StateError('测试统计失败');
    if (delayed) {
      final result = Completer<TrafficSummary>();
      pending.add(result);
      return result.future;
    }
    return fixture(hourly: hourly, empty: empty);
  }

  void publish() => notifyListeners();
}

void main() {
  test('区间数据不可变且保持内核提供的时间标签', () {
    final data = fixture();
    expect(data.buckets.length, 720);
    expect(data.zoneId, 'Asia/Shanghai');
    expect(data.buckets.first.label, contains('+08:00'));
    expect(() => data.buckets.clear(), throwsUnsupportedError);
    expect(data.buckets[1].recordCount, 1);
    expect(data.buckets[1].sentBytes, 0);
    expect(data.buckets[2].recordCount, 0);
  });
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('小时历史折线在宽窄窗口显示固定最近一个月 $platform $brightness', (tester) async {
        final kernel = SummaryKernel()..connected = true;
        addTearDown(kernel.dispose);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final width in [1000.0, 480.0]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpWidget(
            MaterialApp(
              theme: desktopTheme(brightness).copyWith(platform: platform),
              home: Scaffold(body: TrafficHistoryDialog(proxy: kernel)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('最近 1 个月 · 按小时统计 · 保留最近 12 个月'), findsOneWidget);
          expect(find.byType(TrafficSummaryChart), findsOneWidget);
          expect(
            find.byKey(const ValueKey('traffic-line-chart')),
            findsOneWidget,
          );
          expect(find.text('每小时流量 · 代理与直连'), findsOneWidget);
          expect(find.byType(SegmentedButton<int>), findsNothing);
          expect(tester.takeException(), isNull);
        }
        expect(kernel.requests, everyElement(isTrue));
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('历史加载失败可重试，关闭后迟到响应不会更新已释放页面', (tester) async {
    final kernel = SummaryKernel()
      ..connected = true
      ..fail = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TrafficHistoryDialog(proxy: kernel)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('测试统计失败'), findsOneWidget);
    kernel.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(TrafficSummaryChart), findsOneWidget);
    kernel.delayed = true;
    await tester.tap(find.byTooltip('刷新统计'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    kernel.pending.single.complete(fixture());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
