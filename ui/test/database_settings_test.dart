import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/database_settings.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/database_preferences.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/database_settings_dialog.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop;

class SwitchingKernel extends ProxyController {
  SwitchingKernel(Directory directory) : super(directory: directory);
  int stops = 0, starts = 0;
  bool reject = false;
  @override
  Future<void> shutdown() async {
    stops++;
    connected = running = false;
  }

  @override
  Future<void> connect(
    ProxyProfile profile,
    String resources, {
    bool launch = true,
  }) async {
    starts++;
    if (reject) throw StateError('测试数据库无法连接');
    connected = true;
    storageBackend = databaseSettings.type;
    kernelGeneration++;
    appliedProfile = ProxyProfile(connections: [], defaultConnectionId: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('properties 保留密码中的空格、换行、反斜杠和中文，原子保存使用私有权限', () async {
    final directory = await Directory.systemTemp.createTemp(
      'database-settings-',
    );
    final store = DatabasePreferences();
    const value = DatabaseSettings(
      type: 'postgresql',
      username: 'postgres',
      password: ' 空格\\密码\n\t=:#🔑 ',
      verifyTls: false,
    );
    try {
      await store.write(directory, value);
      final loaded = await store.read(directory);
      expect(loaded.password, value.password);
      expect(loaded.verifyTls, isFalse);
      expect(await store.file(directory).readAsString(), value.encode());
      expect(directory.listSync().length, 1);
      if (!Platform.isWindows) {
        final file = await store.file(directory).stat();
        expect(file.mode & 0x1ff, 0x180);
      }
      await expectLater(
        store.write(
          directory,
          const DatabaseSettings(
            type: 'mysql',
            port: '99999',
            username: 'test',
          ),
        ),
        throwsFormatException,
      );
      expect((await store.read(directory)).password, value.password);
      expect(
        () => DatabaseSettings.decode(
          'type=postgresql\npassword=secret\nunknown=1',
        ),
        throwsFormatException,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('切换失败保留所选配置、不回退，关闭 TUN 后才允许切换', () async {
    final directory = await Directory.systemTemp.createTemp('database-switch-');
    final kernel = SwitchingKernel(directory)..reject = true;
    const value = DatabaseSettings(
      type: 'mysql',
      port: '3306',
      username: 'test',
      password: 'secret',
    );
    try {
      kernel.tunState = 'running';
      await expectLater(
        kernel.changeDatabase(value, ProxyProfile(), ''),
        throwsStateError,
      );
      expect(kernel.stops, 0);
      kernel.tunState = 'off';
      await expectLater(
        kernel.changeDatabase(value, ProxyProfile(), ''),
        throwsStateError,
      );
      expect(kernel.stops, 1);
      expect(kernel.starts, 1);
      expect((await kernel.databases.read(directory)).type, 'mysql');
      expect(kernel.changingDatabase, isFalse);
      expect(kernel.connected, isFalse);
      expect(kernel.redact('secret'), '***');
      kernel.reject = false;
      await kernel.changeDatabase(
        DatabaseSettings(path: '${directory.path}/kernel.db'),
        ProxyProfile(),
        '',
      );
      expect(kernel.storageBackend, 'sqlite');
      expect(kernel.appliedProfile!.connections, isEmpty);
    } finally {
      kernel.dispose();
      await directory.delete(recursive: true);
    }
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('数据库表单选择、密码隐藏和保存结果 $platform $brightness', (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('database-dialog-'),
        ))!;
        final kernel = SwitchingKernel(directory)
          ..connected = true
          ..storageBackend = 'sqlite';
        final model = ProxyViewModel(
          proxy: kernel,
          native: TestDesktop(directory),
        )..loading = false;
        model.accept(ProxyProfile(connections: [], defaultConnectionId: ''));
        tester.view.physicalSize = brightness == Brightness.dark
            ? const Size(640, 600)
            : const Size(860, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(() async {
          model.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness).copyWith(platform: platform),
            home: Scaffold(body: DatabaseSettingsDialog(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownMenu<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('PostgreSQL').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('database-path')), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('database-username')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('database-username')),
          'postgres',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('database-password')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('database-password')),
          '界面测试密码',
        );
        final password = find.descendant(
          of: find.byKey(const ValueKey('database-password')),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(password).obscureText, isTrue);
        await tester.tap(find.byTooltip('显示密码'));
        await tester.pump();
        expect(tester.widget<TextField>(password).obscureText, isFalse);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('save-database')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(kernel.storageBackend, 'postgresql');
        expect(kernel.stops, 1);
        expect(find.textContaining('数据库已切换为 PostgreSQL'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
