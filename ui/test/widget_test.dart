import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/desktop_icons.dart';
import 'package:network_ui/ui/widgets/desktop_select.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('network-ui-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method == 'environment') {
            return {'support': directory.path, 'resources': directory.path};
          }
          return null;
        });
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  testWidgets('概览和配置页面在桌面尺寸下可用', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NetworkApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('代理概览'), findsOneWidget);
    expect(find.text('开启'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(DesktopIcons.connections)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('连接配置  Ctrl/⌘+2'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection-name')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('edit-default')));
    await tester.pumpAndSettle();
    expect(find.text('应用并保存'), findsOneWidget);
    expect(find.text('保存到内核'), findsNothing);
    expect(find.text('服务端地址'), findsOneWidget);
    final protocol = find.byKey(const ValueKey('protocol-selector'));
    await tester.ensureVisible(protocol);
    await tester.tap(
      find.descendant(of: protocol, matching: find.text('HTTP/3')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MenuItemButton).hitTestable().first);
    await tester.pumpAndSettle();
    expect(tester.widget<DesktopSelect<String>>(protocol).value, 'http2');
    await tester.tap(
      find.descendant(of: protocol, matching: find.text('HTTP/2')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MenuItemButton).hitTestable().last);
    await tester.pumpAndSettle();
    expect(tester.widget<DesktopSelect<String>>(protocol).value, 'http3');
    await tester.ensureVisible(find.byKey(const ValueKey('field-password')));
    expect(find.text('密码'), findsOneWidget);
    await tester.tap(find.text('路由规则').first);
    await tester.pumpAndSettle();
    expect(find.text('应用直连规则'), findsOneWidget);
    await tester.tap(find.text('运行日志').first);
    await tester.pumpAndSettle();
    expect(find.text('暂无日志'), findsOneWidget);
    await tester.tap(find.text('连接诊断').first);
    await tester.pumpAndSettle();
    expect(find.text('查询路由'), findsOneWidget);
    tester.view.physicalSize = const Size(720, 540);
    await tester.pumpAndSettle();
    for (final brightness in [Brightness.light, Brightness.dark]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      for (final label in ['概览', '连接配置', '路由规则', '运行日志', '连接诊断', '活跃隧道']) {
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$label / $brightness');
      }
    }
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });

  testWidgets('侧栏品牌在常见窗口宽度保持原型位置，顶栏拖动区域不覆盖状态', (tester) async {
    final methods = <String>[];
    final dragEdges = <double>[];
    final titlebarGeometry = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          methods.add(call.method);
          if (call.method == 'configureTitlebar') {
            final geometry = call.arguments as Map<Object?, Object?>;
            titlebarGeometry.add(geometry);
            dragEdges.add(geometry['right']! as double);
          }
          if (call.method == 'environment') {
            return {'support': directory.path, 'resources': directory.path};
          }
          return null;
        });
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NetworkApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('desktop-titlebar'));
    expect(tester.getRect(header), const Rect.fromLTWH(185, 0, 935, 56));
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('代理客户端'), findsNothing);
    for (final text in ['代理概览']) {
      expect(tester.getCenter(find.text(text)).dy, closeTo(28, 1));
    }
    expect(
      tester.getRect(find.byKey(const ValueKey('desktop-navigation'))).top,
      0,
    );
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.text('退出内核'), findsNothing);
    expect(find.textContaining('实时状态'), findsNothing);
    expect(dragEdges, hasLength(1));
    expect(titlebarGeometry.single['top'], 0);
    expect(titlebarGeometry.single['height'], 56);
    expect(dragEdges.single, lessThanOrEqualTo(tester.getRect(header).right));
    for (final width in [1120.0, 864.0, 720.0]) {
      tester.view.physicalSize = Size(width, 642);
      await tester.pumpAndSettle();
      expect(titlebarGeometry.last['top'], 0);
      expect(titlebarGeometry.last['height'], 56);
      final brand = tester.getRect(find.byKey(const ValueKey('desktop-brand')));
      final navigation = tester.getRect(
        find.byKey(const ValueKey('desktop-navigation')),
      );
      expect(brand.top, 72);
      expect(brand.right, lessThanOrEqualTo(navigation.right));
      expect(navigation.width, width < 760 ? 150 : 184);
      expect(find.text('Network'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个桌面平台共享主题布局并支持窗口缩放和键盘焦点', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalPlatform = debugDefaultTargetPlatformOverride;
    addTearDown(() => debugDefaultTargetPlatformOverride = originalPlatform);
    final model = ProxyViewModel();
    addTearDown(model.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(NetworkApp(model: model));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    ThemeData? reference;
    Rect? referenceField;
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(1120, 780);
      model.navigate(1);
      await tester.pumpWidget(NetworkApp(model: model));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('field-server.host'));
      if (field.evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('edit-default')));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(field));
      expect(theme.platform, platform);
      reference ??= theme;
      referenceField ??= tester.getRect(field);
      expect(theme.colorScheme, reference.colorScheme);
      expect(theme.textTheme, reference.textTheme);
      expect(theme.inputDecorationTheme, reference.inputDecorationTheme);
      expect(theme.textTheme.bodyMedium!.fontFamily, DesktopDesign.fontFamily);
      expect(tester.getRect(field), referenceField);
      expect(find.byType(NavigationDrawer), findsOneWidget);
      expect(
        tester.getSize(find.byType(NavigationDrawer)).width,
        DesktopDesign.navigationWidth,
      );
      await tester.enterText(field, 'desktop.example');
      await tester.pumpAndSettle();
      final hostEditor = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      tester.widget<EditableText>(hostEditor).focusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(hostEditor).focusNode.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final port = find.descendant(
        of: find.byKey(const ValueKey('field-username')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(port).focusNode.hasFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        tester.widget<EditableText>(hostEditor).focusNode.hasFocus,
        isTrue,
      );
      for (final size in [
        const Size(720, 540),
        const Size(860, 640),
        const Size(1600, 900),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(model.fields['server.host']!.text, 'desktop.example');
        expect(model.page, 1);
        expect(find.byType(NavigationDrawer), findsOneWidget);
        expect(find.byType(NavigationRail), findsNothing);
        final page = find.byKey(const PageStorageKey('configuration'));
        expect(
          tester.getSize(page).width,
          lessThanOrEqualTo(DesktopDesign.contentMaxWidth),
        );
        expect(tester.takeException(), isNull, reason: '$platform / $size');
      }
      expect(tester.takeException(), isNull);
    }
    debugDefaultTargetPlatformOverride = originalPlatform;
  });

  testWidgets('连接页切换后保留搜索、列表模式与侧边编辑草稿', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = ProxyViewModel();
    addTearDown(model.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(NetworkApp(model: model));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    model.navigate(1);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('edit-${model.editingId}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('connection-name')),
      '未应用的连接名称',
    );
    await tester.enterText(
      find.byKey(const ValueKey('connection-search')),
      '没有匹配的目标',
    );
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    model.navigate(3);
    await tester.pumpAndSettle();
    model.navigate(1);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('connection-search')))
          .controller!
          .text,
      '没有匹配的目标',
    );
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {false},
    );
    expect(model.connectionName.text, '未应用的连接名称');
    expect(find.text('没有匹配的连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('高级连接参数展开后输入框尺寸正常且可编辑', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NetworkApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    final advanced = find.byKey(const PageStorageKey('connection-parameters'));
    await tester.tap(find.byKey(const ValueKey('edit-default')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      advanced,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('connection-editor')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('连接参数'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final values = {
      'connectTimeoutMillis': '12000',
      'idleTimeoutSeconds': '90',
      'maxStreams': '256',
    };
    for (final entry in values.entries) {
      final field = find.byKey(ValueKey('field-${entry.key}'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(tester.getSize(field).height, inInclusiveRange(25, 50));
      // 隐藏滚动条后，只保留面板原有内边距，不额外占用表单宽度。
      expect(
        tester
                .getRect(find.byKey(const PageStorageKey('configuration')))
                .right -
            tester.getRect(field).right,
        greaterThanOrEqualTo(14),
      );
      await tester.enterText(field, entry.value);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('设置…'));
    await tester.pumpAndSettle();
    final runtime = find.byKey(const PageStorageKey('kernel-runtime'));
    await tester.scrollUntilVisible(
      runtime,
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('settings')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('内核运行环境'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('内核运行环境'));
    await tester.pumpAndSettle();
    final java = find
        .descendant(of: runtime, matching: find.byType(TextField))
        .first;
    await tester.ensureVisible(java);
    await tester.enterText(java, '/临时测试/java/bin/java');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭设置（保留草稿）'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(860, 640);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    await tester.tap(find.text('运行日志').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    for (final entry in values.entries) {
      final field = find.byKey(ValueKey('field-${entry.key}'));
      await tester.scrollUntilVisible(
        field,
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('connection-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.widget<TextField>(field).controller!.text, entry.value);
      expect(tester.getSize(field).height, inInclusiveRange(25, 50));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('启动只读取当前配置，不读取旧文件或访问钥匙串', (tester) async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          methods.add(call.method);
          if (call.method == 'environment') {
            return {'support': directory.path, 'resources': directory.path};
          }
          return null;
        });
    await tester.runAsync(
      () =>
          File('${directory.path}/profile.json')
              .writeAsString('旧配置不再解析，即使内容无效也不影响启动'),
    );
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NetworkApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    for (final key in ['server.host', 'password']) {
      if (find.byKey(const ValueKey('connection-name')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('edit-default')));
        await tester.pumpAndSettle();
      }
      final field = find.byKey(ValueKey('field-$key'));
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    }
    expect(methods, contains('environment'));
    expect(
      methods.every(
        (method) => {
          'environment',
          'desktopState',
          'configureTitlebar',
        }.contains(method),
      ),
      isTrue,
    );
    expect(find.textContaining('加载配置失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面快捷键保留草稿，密码显隐及批量规则编辑可用', (tester) async {
    tester.view.physicalSize = const Size(860, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NetworkApp());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    Future<void> shortcut(
      LogicalKeyboardKey key, {
      bool control = false,
    }) async {
      final modifier = control
          ? LogicalKeyboardKey.controlLeft
          : LogicalKeyboardKey.metaLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    await shortcut(LogicalKeyboardKey.digit2);
    await tester.tap(find.byKey(const ValueKey('edit-default')));
    await tester.pumpAndSettle();
    final host = find.byKey(const ValueKey('field-server.host'));
    await tester.ensureVisible(host);
    await tester.enterText(host, 'example.com');
    final password = find.byKey(const ValueKey('field-password'));
    await tester.ensureVisible(password);
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isFalse);
    await shortcut(LogicalKeyboardKey.digit4);
    await tester.tap(find.text('批量编辑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rules-editor')), findsOneWidget);
    expect(find.text('规则文件'), findsNothing);
    await shortcut(LogicalKeyboardKey.comma, control: true);
    expect(find.text('本地代理'), findsOneWidget);
    final localPort = find.byKey(const ValueKey('field-port'));
    await tester.ensureVisible(localPort);
    await tester.enterText(localPort, '8888');
    await tester.tap(find.byTooltip('关闭设置（保留草稿）'));
    await tester.pumpAndSettle();
    await shortcut(LogicalKeyboardKey.digit2);
    await tester.ensureVisible(host);
    expect(tester.widget<TextField>(host).controller!.text, 'example.com');
    Future<void> nativeAction(String method, [Object? arguments]) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'network_ui/desktop',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
      await tester.pumpAndSettle();
    }

    await nativeAction('navigate', 3);
    expect(find.text('暂无日志'), findsOneWidget);
    await nativeAction('showSettings');
    expect(find.text('本地代理'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('field-port')))
          .controller!
          .text,
      '8888',
    );
    await tester.tap(find.byTooltip('关闭设置（保留草稿）'));
    await tester.pumpAndSettle();
    await shortcut(LogicalKeyboardKey.digit2);
    await tester.ensureVisible(host);
    expect(tester.widget<TextField>(host).controller!.text, 'example.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('运行中跟随系统明暗变化并保留草稿和页面', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final model = ProxyViewModel();
    addTearDown(model.dispose);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.runAsync(() async {
      await tester.pumpWidget(NetworkApp(model: model));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接配置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-default')));
    await tester.pumpAndSettle();
    final host = find.byKey(const ValueKey('field-server.host'));
    await tester.ensureVisible(host);
    await tester.enterText(host, 'theme-test.example');
    final light = Theme.of(tester.element(host)).scaffoldBackgroundColor;
    for (final brightness in [Brightness.dark, Brightness.light]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(host));
      expect(theme.brightness, brightness);
      expect(
        theme.scaffoldBackgroundColor == light,
        brightness == Brightness.light,
      );
      expect(model.page, 1);
      expect(model.fields['server.host']!.text, 'theme-test.example');
      expect(model.dirty, isTrue);
      await tester.tap(find.byTooltip('重新读取内核配置'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        brightness,
      );
      await tester.tap(find.text('保留草稿'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('查看历史日志不会被新日志打断，可以恢复跟随', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = ProxyViewModel();
    addTearDown(model.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(NetworkApp(model: model));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    for (var i = 0; i < 100; i++) {
      model.proxy.addLog('INFO 日志记录 $i');
    }
    await tester.tap(find.text('运行日志').first);
    await tester.pumpAndSettle();
    final scroll = model.logScroll;
    expect(scroll.position.extentAfter, 0);
    await tester.drag(
      find.byWidgetPredicate(
        (widget) => widget is ListView && widget.controller == model.logScroll,
      ),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(find.text('跳到最新'), findsOneWidget);
    final offset = scroll.offset;
    model.proxy.addLog('INFO 新收到的日志');
    await tester.pumpAndSettle();
    expect(scroll.offset, offset);
    await tester.tap(find.text('跳到最新'));
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, 0);
    await tester.tap(find.byTooltip('暂停日志'));
    await tester.pump();
    model.proxy.addLog('INFO 暂停后的日志');
    await tester.pumpAndSettle();
    expect(find.text('暂停后的日志'), findsNothing);
    expect(find.text('显示已暂停，内核继续记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('内核快照保留密码标志，空密码字段不会提交且保留当前直连规则', () {
    final profile = ProxyProfile.fromKernel({
      'version': 1,
      'local': {'routesInline': 'example.com'},
      'defaultConnectionId': 'one',
      'connections': [
        {
          'id': 'one',
          'name': '连接',
          'hasPassword': true,
          'config': {'server.host': 'localhost'},
        },
      ],
    });
    expect(profile.validate(), isNull);
    expect(profile.selected.values['password'], isEmpty);
    expect(
      (profile.selected.json()['config'] as Map).containsKey('password'),
      isFalse,
    );
    expect(profile.localConfiguration['routesInline'], 'example.com');
    expect(profile.localConfiguration.containsKey('routesFile'), isFalse);
  });

  test('拒绝无效端口与不完整服务端配置', () {
    final profile = ProxyProfile();
    expect(profile.validate(), contains('服务端'));
    profile.selected.values.addAll({
      'server.host': 'localhost',
      'password': 'secret',
      'port': '65536',
    });
    profile.values['port'] = '65536';
    expect(profile.validate(), contains('本地端口'));
    profile.values['port'] = '8080';
    expect(profile.validate(), isNull);
  });
}
