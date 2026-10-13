import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/traffic_summary.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/traffic_history_dialog.dart';

class PreviewSummaryKernel extends ProxyController {
  @override
  Future<TrafficSummary> trafficSummary(TrafficWindow window) async {
    final times = window.boundaries;
    final buckets = [
      for (var i = 0; i < times.length - 1; i++)
        {
          'from': times[i].millisecondsSinceEpoch,
          'to': times[i + 1].millisecondsSinceEpoch,
          'sentBytes': i < DateTime.now().hour ? (i % 5 + 1) * 1250000 : 0,
          'receivedBytes': i < DateTime.now().hour ? (i % 7 + 1) * 22400000 : 0,
          'recordCount': i < DateTime.now().hour ? 60 : 0,
        },
    ];
    return TrafficSummary.fromJson({
      'buckets': buckets,
      'sentBytes': buckets.fold<int>(0, (sum, b) => sum + b['sentBytes']!),
      'receivedBytes': buckets.fold<int>(
        0,
        (sum, b) => sum + b['receivedBytes']!,
      ),
      'recordCount': DateTime.now().hour * 60,
      'latestMinuteStart':
          DateTime.now().millisecondsSinceEpoch ~/ 60000 * 60000,
    });
  }
}

void main() {
  final destination = Platform.environment['UI_PREVIEW_DIR'];
  testWidgets('历史统计真实字体明暗宽窄预览', (tester) async {
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
    for (final brightness in Brightness.values) {
      for (final width in [1000.0, 480.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(body: TrafficHistoryDialog(proxy: proxy)),
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
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(destination!).create(recursive: true);
          await File(
            '$destination/history-${brightness.name}-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  }, skip: destination == null);
}
