import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/access_records_page.dart';
import 'package:network_ui/ui/widgets/configuration_transfer.dart';

import 'configuration_transfer_test.dart'
    show TransferDesktop, TransferKernel, TransferModel;
import 'history_records_test.dart' show HistoryKernel;

void main() {
  final destination = Platform.environment['UI_TRANSFER_PREVIEW_DIR'];
  testWidgets('配置导出与域名统计明暗宽窄预览', (tester) async {
    final kernel = TransferKernel()
      ..publish(
        ProxyProfile(
          defaultConnectionId: 'a',
          connections: [
            ConnectionProfile(
              id: 'a',
              name: '家中服务端',
              config: {'server.host': 'home.example', 'protocol': 'http2'},
            ),
            ConnectionProfile(
              id: 'b',
              name: '备用服务端',
              config: {'server.host': 'backup.example'},
            ),
          ],
        ),
        1,
      );
    final model = TransferModel(proxy: kernel, native: TransferDesktop())
      ..loading = false;
    model.accept(kernel.appliedProfile!);
    addTearDown(model.dispose);
    final history = HistoryKernel()..connected = true;
    addTearDown(history.dispose);
    await tester.runAsync(() async {
      for (final entry in {
        'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
        DesktopDesign.fontFamily: 'assets/fonts/NotoSansSC-Variable.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
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
        for (final access in [false, true]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              theme: desktopTheme(brightness),
              builder: (context, child) =>
                  RepaintBoundary(key: boundary, child: child!),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: access
                      ? AccessRecordsPage(proxy: history)
                      : ConfigurationTransfer(model: model, routes: false),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (!access) {
            await tester.tap(find.text('导出连接'));
            await tester.pumpAndSettle();
          }
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
              '$destination/${access ? 'access' : 'export'}-${brightness.name}-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
  }, skip: destination == null);
}
