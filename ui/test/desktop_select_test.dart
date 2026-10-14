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
  testWidgets('实时刷新发生在按下与松开之间仍能选中筛选项', (tester) async {
    String? selected = 'direct';
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) {
              refresh = update;
              return SizedBox(
                width: 160,
                child: DesktopSelect<String>(
                  value: selected,
                  options: [('all', '全部路由'), ('proxy', '代理'), ('direct', '直连')],
                  onSelected: (value) => update(() => selected = value),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final item = find.widgetWithText(MenuItemButton, '代理').hitTestable();
    final gesture = await tester.startGesture(
      tester.getCenter(item),
      kind: ui.PointerDeviceKind.mouse,
    );
    refresh(() {});
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 'proxy');
    expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
  });

  testWidgets('选项改名、外部选中值和主题变化及时更新', (tester) async {
    var selected = 'http2';
    var label = '原名称';
    var brightness = Brightness.light;
    late StateSetter refresh;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, update) {
          refresh = update;
          return MaterialApp(
            theme: desktopTheme(brightness),
            home: Scaffold(
              body: DesktopSelect<String>(
                value: selected,
                options: [('http2', label), ('http3', '另一个选项')],
                onSelected: (value) => update(() => selected = value!),
              ),
            ),
          );
        },
      ),
    );
    refresh(() => label = '修改后的名称');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '修改后的名称',
    );
    refresh(() {
      selected = 'http3';
      brightness = Brightness.dark;
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '另一个选项',
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check)).color,
      desktopTheme(Brightness.dark).colorScheme.primary,
    );
    await tester.tap(
      find.widgetWithText(MenuItemButton, '修改后的名称').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(selected, 'http2');
  });

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
