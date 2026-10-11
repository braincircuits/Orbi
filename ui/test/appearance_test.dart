import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/services/appearance_preferences.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/ui/pages/settings_dialog.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class _Appearance extends AppearancePreferences {
  ThemeMode saved = ThemeMode.system;
  Completer<void>? pending;
  bool fail = false;

  @override
  Future<ThemeMode> read(Directory directory) async => saved;

  @override
  Future<void> write(Directory directory, ThemeMode mode) async {
    await pending?.future;
    if (fail) throw const FileSystemException('测试写入失败');
    saved = mode;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('network-appearance-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
  });
  tearDown(() => directory.delete(recursive: true));

  test('外观设置首次跟随系统，三种模式落盘后可重新读取且不修改启动路径', () async {
    final runtime = File('${directory.path}/ui.json');
    await runtime.writeAsString('原有启动设置');
    expect(await AppearancePreferences().read(directory), ThemeMode.system);
    for (final mode in ThemeMode.values) {
      await AppearancePreferences().write(directory, mode);
      expect(await AppearancePreferences().read(directory), mode);
      expect(await runtime.readAsString(), '原有启动设置');
      expect(
        await File('${directory.path}/appearance.json.tmp').exists(),
        false,
      );
    }
  });

  test('外观设置损坏不阻止内核初始化，也不删除损坏文件', () async {
    final file = File('${directory.path}/appearance.json');
    await file.writeAsString('损坏内容');
    final model = ProxyViewModel(
      native: TestDesktop(directory),
      proxy: TestKernel(),
    );
    final errors = <String>[];
    final subscription = model.messages.stream.listen(
      (message) => errors.add(message.text),
    );
    await model.initialize();
    expect(model.loading, false);
    expect(model.themeMode.value, ThemeMode.system);
    expect(errors, contains('读取外观设置失败，暂时跟随系统外观。'));
    expect(await file.readAsString(), '损坏内容');
    await subscription.cancel();
    model.dispose();
  });

  test('主题即时更新，写入期间不并发覆盖，失败恢复原值并允许重试', () async {
    final appearance = _Appearance()..pending = Completer<void>();
    final kernel = TestKernel();
    final model = ProxyViewModel(
      native: TestDesktop(directory),
      proxy: kernel,
      appearancePreferences: appearance,
    );
    await model.initialize();
    final messages = <String>[];
    final subscription = model.messages.stream.listen(
      (message) => messages.add(message.text),
    );
    final saving = model.setThemeMode(ThemeMode.dark);
    expect(model.themeMode.value, ThemeMode.dark);
    expect(model.savingAppearance, true);
    await model.setThemeMode(ThemeMode.light);
    expect(model.themeMode.value, ThemeMode.dark);
    appearance.fail = true;
    appearance.pending!.complete();
    await saving;
    expect(model.themeMode.value, ThemeMode.system);
    expect(model.savingAppearance, false);
    expect(messages, contains('保存外观设置失败，已恢复原来的主题，请重试。'));
    appearance.fail = false;
    await model.setThemeMode(ThemeMode.light);
    expect(appearance.saved, ThemeMode.light);
    expect(kernel.writes, isEmpty);
    await subscription.cancel();
    model.dispose();
  });

  testWidgets('设置切换主题保留草稿与页面，固定外观忽略系统变化，重新启动恢复选择', (tester) async {
    tester.view.physicalSize = const Size(860, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    final appearance = _Appearance();
    final kernel = TestKernel();
    final model = ProxyViewModel(
      native: TestDesktop(directory),
      proxy: kernel,
      appearancePreferences: appearance,
    );
    await tester.runAsync(model.initialize);
    addTearDown(model.dispose);
    model.navigate(1);
    model.connectionName.text = '尚未应用的草稿';
    model.changed('');
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置…'));
    await tester.pumpAndSettle();

    Future<void> select(String label) async {
      final selector = find.byKey(const ValueKey('theme-mode-selector'));
      await tester.tap(
        find.descendant(of: selector, matching: find.byType(TextField)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, label).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Brightness brightness() =>
        Theme.of(tester.element(find.byType(SettingsDialog))).brightness;

    await select('深色');
    expect(brightness(), Brightness.dark);
    expect(model.dirty, true);
    expect(model.page, 1);
    expect(model.connectionName.text, '尚未应用的草稿');
    expect(kernel.writes, isEmpty);
    await select('浅色');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    await select('跟随系统');
    expect(brightness(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    await select('深色');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    expect(model.page, 1);
    await tester.pumpWidget(const SizedBox());
    final restored = ProxyViewModel(
      native: TestDesktop(directory),
      proxy: TestKernel(),
      appearancePreferences: appearance,
    );
    addTearDown(restored.dispose);
    await tester.runAsync(restored.initialize);
    await tester.pumpWidget(NetworkApp(model: restored));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
