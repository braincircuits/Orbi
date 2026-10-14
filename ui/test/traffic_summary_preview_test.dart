import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_summary_test.dart' show SummaryKernel;

import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/traffic_history_dialog.dart';
import 'package:network_ui/models/traffic_summary.dart';
import 'package:network_ui/ui/widgets/traffic_chart.dart';

class PreviewSummaryKernel extends SummaryKernel {
  @override
  Future<TrafficSummary> trafficSummary({bool hourly = true}) async {
    final step = hourly ? 3600000 : 60000;
    final count = hourly ? 720 : 1440;
    final start = DateTime.utc(2026, 9, 15).millisecondsSinceEpoch;
    final buckets = List.generate(count, (index) {
      final time = DateTime.fromMillisecondsSinceEpoch(
        start + index * step,
        isUtc: true,
      );
      final missing = index % 120 >= 110;
      final bytes = (1000000 * (2 + math.sin(index * .2))).round();
      final label = time
          .toIso8601String()
          .substring(0, 16)
          .replaceAll('T', ' ');
      return <String, Object>{
        'from': start + index * step,
        'to': start + (index + 1) * step,
        'sentBytes': missing ? 0 : bytes,
        'receivedBytes': missing ? 0 : bytes * 3,
        'recordCount': missing ? 0 : 1,
        'label': '$label +00:00',
        'shortLabel': hourly ? label.substring(5) : label.substring(11),
      };
    });
    return TrafficSummary.fromJson({
      'from': start,
      'to': start + count * step,
      'zoneId': 'UTC',
      'interval': hourly ? 'hour' : 'minute',
      'sentBytes': buckets.fold<int>(
        0,
        (sum, b) => sum + (b['sentBytes']! as int),
      ),
      'receivedBytes': buckets.fold<int>(
        0,
        (sum, b) => sum + (b['receivedBytes']! as int),
      ),
      'recordCount': buckets.fold<int>(
        0,
        (sum, b) => sum + (b['recordCount']! as int),
      ),
      'buckets': buckets,
    });
  }
}

void main() {
  final destination = Platform.environment['UI_PREVIEW_DIR'];
  testWidgets('分钟趋势与小时历史真实字体明暗宽窄预览', (tester) async {
    final proxy = PreviewSummaryKernel()..connected = true;
    addTearDown(proxy.dispose);
    await tester.runAsync(() async {
      for (final entry in {
        'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
        'RobotoMono': 'assets/fonts/RobotoMono-Variable.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        DesktopDesign.fontFamily: 'assets/fonts/NotoSansSC-Variable.ttf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    for (final hourly in [true, false]) {
      for (final brightness in Brightness.values) {
        for (final width in [1000.0, 480.0]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpWidget(
            MaterialApp(
              theme: desktopTheme(brightness),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: hourly
                      ? TrafficHistoryDialog(proxy: proxy)
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: TrafficChart(proxy: proxy),
                        ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(destination!).create(recursive: true);
            await File(
              '$destination/${hourly ? 'history' : 'trend'}-${brightness.name}-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
  }, skip: destination == null);
}
