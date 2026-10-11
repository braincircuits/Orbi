import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class _DesktopModel extends ProxyViewModel {
  @override
  Future<void> initialize() async {
    accept(ProxyProfile(values: {'server.host': 'desktop.example'}));
    loading = false;
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
  });

  testWidgets('窄窗口放大文字时页面与可关闭错误提示保持可用', (tester) async {
    tester.view.physicalSize = const Size(720, 540);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final model = _DesktopModel();
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      for (final page in [0, 1, 4, 2, 5, 3]) {
        model.navigate(page);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$brightness / $page');
      }
      model.message('无法连接内核，请检查连接状态后重试。', failure: true);
      await tester.pumpAndSettle();
      final message = find.byKey(const ValueKey('desktop-message'));
      expect(message, findsOneWidget);
      final rect = tester.getRect(
        find.descendant(of: message, matching: find.byType(Material)).first,
      );
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(704));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      final close = find.descendant(
        of: message,
        matching: find.byType(IconButton),
      );
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(message, findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('处理中移除表单键盘焦点，恢复后保留草稿', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _DesktopModel();
    addTearDown(model.dispose);
    await tester.pumpWidget(NetworkApp(model: model));
    model.navigate(2);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('rules-editor'));
    await tester.enterText(field, 'example.com');
    final editor = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    editor.focusNode.requestFocus();
    await tester.pump();
    expect(editor.focusNode.hasFocus, isTrue);
    model.update(() => model.working = true);
    await tester.pump();
    expect(editor.focusNode.hasFocus, isFalse);
    expect(editor.focusNode.canRequestFocus, isFalse);
    model.update(() => model.working = false);
    await tester.pumpAndSettle();
    expect(model.rules.text, 'example.com');
    await tester.tap(field);
    await tester.pump();
    expect(editor.focusNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
