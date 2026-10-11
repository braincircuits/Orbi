import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/traffic_summary.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/traffic_history_dialog.dart';

TrafficSummary fixture(
  TrafficWindow window, {
  bool empty = false,
  int sent = 1000,
}) {
  final times = window.boundaries;
  return TrafficSummary.fromJson({
    'sentBytes': empty ? 0 : sent,
    'receivedBytes': empty ? 0 : 2000,
    'sampleCount': empty ? 0 : 1,
    'lastSampledAt': empty ? 0 : times.first.millisecondsSinceEpoch,
    'buckets': [
      for (var i = 0; i < times.length - 1; i++)
        {
          'from': times[i].millisecondsSinceEpoch,
          'to': times[i + 1].millisecondsSinceEpoch,
          'sentBytes': !empty && i == 0 ? sent : 0,
          'receivedBytes': !empty && i == 0 ? 2000 : 0,
          'sampleCount': !empty && i == 0 ? 1 : 0,
        },
    ],
  });
}

class SummaryKernel extends ProxyController {
  final windows = <TrafficWindow>[];
  final pending = <Completer<TrafficSummary>>[];
  bool fail = false, empty = false, delayed = false;
  @override
  Future<TrafficSummary> trafficSummary(TrafficWindow window) async {
    windows.add(window);
    if (fail) throw StateError('测试统计失败');
    if (delayed) {
      final result = Completer<TrafficSummary>();
      pending.add(result);
      return result.future;
    }
    return fixture(window, empty: empty);
  }
}

void main() {
  test('本地日历按分、时、日切分，正确处理闰月和跨年', () {
    final hour = TrafficWindow(
      TrafficPeriod.hour,
      DateTime(2026, 10, 11, 19, 35, 26),
    );
    expect(hour.boundaries.length, 61);
    expect(hour.start, DateTime(2026, 10, 11, 19));
    expect(hour.end, DateTime(2026, 10, 11, 20));
    final leap = TrafficWindow(TrafficPeriod.month, DateTime(2024, 2, 29));
    expect(leap.boundaries.length, 30);
    expect(leap.end, DateTime(2024, 3));
    expect(
      TrafficWindow(TrafficPeriod.month, DateTime(2025, 2)).boundaries.length,
      29,
    );
    expect(
      TrafficWindow(TrafficPeriod.month, DateTime(2026, 12)).shift(1).start,
      DateTime(2027),
    );
    for (final date in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
      final day = TrafficWindow(TrafficPeriod.day, date);
      expect(day.boundaries.first, date);
      expect(
        day.boundaries.last,
        DateTime(date.year, date.month, date.day + 1),
      );
      expect(day.boundaries.length - 1, day.end.difference(day.start).inHours);
      expect(day.boundaries.toSet().length, day.boundaries.length);
    }
  });
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('历史统计操作在 $platform $brightness 窄窗口一致', (tester) async {
        final kernel = SummaryKernel()..connected = true;
        addTearDown(kernel.dispose);
        tester.view.physicalSize = const Size(480, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness).copyWith(platform: platform),
            home: Scaffold(body: TrafficHistoryDialog(proxy: kernel)),
          ),
        );
        await tester.pumpAndSettle();
        expect(kernel.windows.last.period, TrafficPeriod.day);
        expect(find.text('按小时统计 · 长期保留'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == '下一日',
                ),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('月'));
        await tester.pumpAndSettle();
        expect(kernel.windows.last.period, TrafficPeriod.month);
        await tester.tap(find.byTooltip('上一月'));
        await tester.pumpAndSettle();
        final month = kernel.windows.last.start;
        final first = find.byKey(const ValueKey('traffic-bucket-0'));
        await tester.ensureVisible(first);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(kernel.windows.last.start, month);
        expect(kernel.windows.last.period, TrafficPeriod.day);
        await tester.ensureVisible(first);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(kernel.windows.last.period, TrafficPeriod.hour);
        expect(kernel.windows.last.boundaries.length, 61);
        expect(find.text('按分钟统计 · 长期保留'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('刷新统计'));
        kernel.fail = true;
        await tester.tap(find.byTooltip('刷新统计'));
        await tester.pumpAndSettle();
        expect(find.textContaining('测试统计失败'), findsOneWidget);
        expect(find.byKey(const ValueKey('traffic-bucket-0')), findsNothing);
        kernel.fail = false;
        kernel.empty = true;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(find.text('此时间段暂无采样记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('月份选择与快速切换不会被旧请求覆盖', (tester) async {
    final kernel = SummaryKernel()..connected = true;
    addTearDown(kernel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: TrafficHistoryDialog(proxy: kernel)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('月'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 月'));
    await tester.pumpAndSettle();
    expect(kernel.windows.last.start, DateTime(DateTime.now().year - 1, 2));
    kernel.delayed = true;
    await tester.tap(find.text('日'));
    await tester.pump();
    final older = kernel.windows.last;
    await tester.tap(find.text('时'));
    await tester.pump();
    final newer = kernel.windows.last;
    kernel.pending.last.complete(fixture(newer, sent: 7000));
    await tester.pump();
    kernel.pending.first.complete(fixture(older, sent: 9000));
    await tester.pumpAndSettle();
    expect(find.text('7.00 KB'), findsOneWidget);
    expect(find.text('9.00 KB'), findsOneWidget); // 7 KB 发送加 2 KB 接收的合计。
    expect(find.text('11.0 KB'), findsNothing);
    expect(find.text('按分钟统计 · 长期保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
