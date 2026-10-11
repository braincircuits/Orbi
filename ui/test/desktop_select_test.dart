import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/desktop_select.dart';

const options = [
  ('http3', 'HTTP/3 · QUIC / UDP'),
  ('http2', 'HTTP/2 · TLS / TCP'),
];

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [720.0, 260.0]) {
      testWidgets('菜单紧凑且从输入框下方展开：${brightness.name} / $width', (tester) async {
        tester.view.physicalSize = Size(width, 200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preview = Platform.environment['UI_SELECT_PREVIEW_DIR'];
        final shadows = debugDisableShadows;
        if (preview != null) {
          debugDisableShadows = false;
          addTearDown(() => debugDisableShadows = shadows);
          await tester.runAsync(() async {
            final font = FontLoader(
              'NotoSansSC',
            )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
            await font.load();
            final icons = FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
            await icons.load();
          });
        }
        final boundary = GlobalKey();
        String? selected = 'http2';
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: desktopTheme(brightness),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: StatefulBuilder(
                    builder: (context, update) => DesktopSelect<String>(
                      value: selected,
                      options: options,
                      onSelected: (value) => update(() => selected = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final field = find.byType(TextField);
        expect(tester.getSize(field).height, 30);
        await tester.tap(field);
        await tester.pumpAndSettle();
        final items = find.byType(MenuItemButton).hitTestable();
        expect(items, findsNWidgets(2));
        final menu = tester.getRect(items.first);
        expect(menu.width, lessThanOrEqualTo(320));
        expect(menu.top, greaterThanOrEqualTo(tester.getRect(field).bottom));
        expect(menu.height, 36);
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (preview != null) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = await Directory(preview).create(recursive: true);
            await File(
              '${directory.path}/${brightness.name}-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(items.first);
        await tester.pumpAndSettle();
        expect(selected, 'http3');
        expect(items, findsNothing);
        expect(
          tester.widget<TextField>(field).controller!.text,
          options.first.$2,
        );
        debugDisableShadows = shadows;
      });
    }
  }

  testWidgets('键盘打开、方向键选择、Enter 确认和 Escape 取消', (tester) async {
    String? selected = 'http2';
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: StatefulBuilder(
              builder: (context, update) => DesktopSelect<String>(
                value: selected,
                options: options,
                onSelected: (value) {
                  if (value != null) update(() => selected = value);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton).hitTestable(), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'http3');
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selected, 'http3');
    expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
  });
}
