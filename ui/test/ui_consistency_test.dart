import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/database_settings_dialog.dart';
import 'package:network_ui/ui/pages/routes_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

double borderHeight(WidgetTester tester, Finder field) {
  final editor = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  return InputDecorator.containerOf(tester.element(editor.first))!.size.height;
}

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('路由与数据库输入框和普通输入框使用相同边框高度：$platform/$brightness', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final model = ProxyViewModel(
          proxy: TestKernel()..connected = true,
          native: TestDesktop(Directory.systemTemp),
        )..loading = false;
        addTearDown(model.dispose);
        const reference = ValueKey('reference-input');
        Future<void> mount(Widget page, double scale) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: desktopTheme(brightness).copyWith(platform: platform),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Column(
                    children: [
                      const TextField(key: reference),
                      Expanded(child: page),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        for (final scale in [1.0, 1.3, 2.0]) {
          await mount(RoutesPage(model: model), scale);
          for (final icon in [Icons.search, Icons.alt_route]) {
            expect(
              tester.getSize(
                find
                    .descendant(
                      of: find.byIcon(icon).first,
                      matching: find.byType(RichText),
                    )
                    .first,
              ),
              const Size.square(DesktopDesign.actionIconSize),
            );
          }
          await tester.tap(find.text('添加直连规则'));
          await tester.pumpAndSettle();
          final expected = borderHeight(tester, find.byKey(reference));
          for (final key in ['route-host', 'route-note']) {
            final field = find.byKey(ValueKey(key));
            expect(
              borderHeight(tester, field),
              closeTo(expected, .01),
              reason: '$key 空值 / $scale',
            );
            expect(
              tester.getSize(field).height,
              closeTo(tester.getSize(find.byKey(reference)).height, .01),
              reason: '$key 外框 / $scale',
            );
            await tester.enterText(field, 'example.com');
            await tester.pumpAndSettle();
            expect(
              borderHeight(tester, field),
              closeTo(expected, .01),
              reason: '$key 输入后 / $scale',
            );
          }
          await mount(DatabaseSettingsDialog(model: model), scale);
          final path = find.byKey(const ValueKey('database-path'));
          expect(
            borderHeight(tester, path),
            closeTo(expected, .01),
            reason: '数据库路径 / $scale',
          );
          expect(
            tester.getSize(path).height,
            closeTo(tester.getSize(find.byKey(reference)).height, .01),
            reason: '数据库路径外框 / $scale',
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
