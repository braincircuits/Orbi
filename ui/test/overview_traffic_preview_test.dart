import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/overview_page.dart';

import 'overview_test.dart' show fixture, ReadyOverviewModel;
import 'traffic_fixture.dart';

void main() {
  final destination = Platform.environment['UI_PREVIEW_DIR'];
  testWidgets('概览真实字体的明暗与宽窄窗口预览', (tester) async {
    final (directory, _, proxy) = (await tester.runAsync(fixture))!;
    final model = ReadyOverviewModel(proxy, directory);
    proxy.traffic = TrafficSnapshot.merge(null, trafficFixture(time: 300000));
    addTearDown(() async {
      model.dispose();
      await directory.delete(recursive: true);
    });
    await tester.runAsync(() async {
      for (final entry in {
        'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
        'RobotoMono': 'assets/fonts/RobotoMono-Variable.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
      // 测试环境不提供系统字体，将应用内中文字体注册为首选字体，避免 Ahem 方块字。
      await (FontLoader(DesktopDesign.fontFamily)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
          .load();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    for (final brightness in Brightness.values) {
      for (final width in [900.0, 480.0, 320.0]) {
        tester.view.physicalSize = Size(width, 1600);
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(18),
                  child: OverviewPage(model: model),
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
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(destination!).create(recursive: true);
          await File(
            '$destination/overview-${brightness.name}-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
  }, skip: destination == null);
}
