import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/ui/pages/overview_page.dart';
import 'package:network_ui/ui/pages/routes_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class _Desktop extends NativeBridge {
  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

class _Kernel extends ProxyController {
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) async => AccessRecordPage.fromJson({
    'items': <Map<String, dynamic>>[],
    'hasMore': false,
    'nextValue': 0,
    'nextHost': '',
  });

  void publish(List<TunnelStatus> values) {
    tunnels = values;
    notifyListeners();
  }
}

class _RoutingModel extends ProxyViewModel {
  _RoutingModel({required super.proxy}) : super(native: _Desktop());
  final switches = <(String, String)>[];
  @override
  Future<bool> routeTarget(String target, String route) async {
    switches.add((target, route));
    return true;
  }
}

TunnelStatus _tunnel(
  String id,
  String target,
  String route,
  String state, {
  String originalProtocol = 'tcp',
  String source = '[::1]:50123',
  DateTime? createdAt,
}) => TunnelStatus(
  id: id,
  target: target,
  source: source,
  route: route,
  state: state,
  profileName: route == 'proxy' ? '默认连接' : '',
  protocol: route == 'proxy' ? 'http3' : originalProtocol,
  originalProtocol: originalProtocol,
  createdAt: createdAt ?? DateTime(2026, 10, 10, 18, 20, 30),
);

void main() {
  testWidgets('切换访问记录后搜索文字与隧道筛选保持一致，清空搜索恢复全部路由', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final kernel = _Kernel()..connected = true;
    final model = _RoutingModel(proxy: kernel)..loading = false;
    addTearDown(model.dispose);
    final tunnels = [
      _tunnel('a', 'api.bilibili.com:443', 'direct', 'active'),
      _tunnel('b', 'live.bilibili.com:443', 'proxy', 'active'),
      _tunnel('c', 'example.com:443', 'proxy', 'active'),
    ];
    kernel.publish(tunnels);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: TunnelsPage(model: model)),
      ),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('tunnel-search'));
    await tester.enterText(search, 'bilibili');
    await tester.pumpAndSettle();
    expect(find.text('共 3 条 · 活跃 3 · 等待 0 · 当前显示 2 条'), findsOneWidget);

    await tester.tap(find.text('访问记录'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('access-search')), '历史查询');
    await tester.tap(find.text('实时隧道'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: search, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      'bilibili',
    );
    expect(find.text('全部路由'), findsOneWidget);
    expect(find.text('example.com:443'), findsNothing);
    expect(find.text('共 3 条 · 活跃 3 · 等待 0 · 当前显示 2 条'), findsOneWidget);

    await tester.tap(find.text('全部路由'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('访问记录'));
    await tester.pumpAndSettle();
    kernel.publish([
      ...tunnels,
      _tunnel('d', 'chat.bilibili.com:443', 'direct', 'active'),
    ]);
    await tester.tap(find.text('实时隧道'));
    await tester.pumpAndSettle();
    expect(find.text('共 4 条 · 活跃 4 · 等待 0 · 当前显示 2 条'), findsOneWidget);
    expect(find.text('chat.bilibili.com:443'), findsOneWidget);
    expect(find.text('live.bilibili.com:443'), findsNothing);

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(find.text('共 4 条 · 活跃 4 · 等待 0 · 当前显示 2 条'), findsOneWidget);
    await tester.tap(find.text('直连').hitTestable().first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '全部路由'));
    await tester.pumpAndSettle();
    expect(find.text('共 4 条 · 活跃 4 · 等待 0'), findsOneWidget);
    for (final tunnel in kernel.tunnels) {
      expect(find.text(tunnel.target), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('实时表格每列双向排序，推送保持排序且路由操作仍对应原目标', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final kernel = _Kernel()..connected = true;
    final model = _RoutingModel(proxy: kernel)..loading = false;
    addTearDown(model.dispose);
    final a = _tunnel(
      'a',
      'a.example:443',
      'direct',
      'active',
      source: '127.0.0.1:1000',
      createdAt: DateTime(2026, 1, 1),
    );
    final b = _tunnel(
      'b',
      'b.example:443',
      'proxy',
      'pending',
      originalProtocol: 'udp',
      source: '127.0.0.1:2000',
      createdAt: DateTime(2026, 1, 2),
    );
    kernel.publish([a, b]);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(body: TunnelsPage(model: model)),
      ),
    );
    await tester.pumpAndSettle();
    bool aFirst() =>
        tester.getTopLeft(find.text(a.target)).dy <
        tester.getTopLeft(find.text(b.target)).dy;
    expect(aFirst(), isFalse);
    for (final (label, firstAscending) in [
      ('目标地址', true),
      ('原始协议', true),
      ('来源地址', true),
      ('路由 / 协议', false),
      ('状态', true),
      ('开始时间', true),
    ]) {
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();
      expect(aFirst(), firstAscending, reason: '$label 升序');
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();
      expect(aFirst(), !firstAscending, reason: '$label 降序');
    }
    kernel.publish([b, a]);
    await tester.pumpAndSettle();
    expect(aFirst(), isFalse);
    await tester.tap(find.byKey(const ValueKey('tunnel-route-a')));
    await tester.pumpAndSettle();
    kernel.publish([a, b]);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '切换为代理'));
    await tester.pumpAndSettle();
    expect(model.switches.last, (a.target, 'proxy'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('路由菜单与列表使用一致字体和表面，紧凑布局在明暗主题下可操作', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final kernel = _Kernel()..connected = true;
    final model = _RoutingModel(proxy: kernel)..loading = false;
    addTearDown(model.dispose);
    kernel.publish([_tunnel('menu', 'example.com:443', 'proxy', 'active')]);
    final preview = Platform.environment['UI_MENU_PREVIEW_DIR'];
    final originalShadows = debugDisableShadows;
    addTearDown(() => debugDisableShadows = originalShadows);
    final boundary = GlobalKey();
    if (preview != null) {
      // 导出实际阴影，避免测试环境用描边代替阴影而影响视觉判断。
      debugDisableShadows = false;
      await tester.runAsync(() async {
        for (final font in {
          DesktopDesign.fontFamily: 'assets/fonts/NotoSansSC-Variable.ttf',
          'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
    }
    model.dirty = true;
    for (final brightness in Brightness.values) {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        tester.view.physicalSize = const Size(592, 430);
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: desktopTheme(brightness),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: TunnelsPage(model: model),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('tunnel-route-menu')),
        );
        await tester.tap(find.byKey(const ValueKey('tunnel-route-menu')));
        await tester.pumpAndSettle();
        final entry = find.widgetWithText(MenuItemButton, '切换为直连');
        expect(tester.getSize(entry).height, 36);
        final surface = find.ancestor(
          of: entry,
          matching: find.byType(Material),
        );
        final materials = tester.widgetList<Material>(surface);
        expect(
          materials.any(
            (material) =>
                material.color ==
                    desktopTheme(brightness)
                        .colorScheme
                        .surfaceContainerLowest &&
                material.elevation == 2,
          ),
          isTrue,
        );
        expect(find.byIcon(Icons.auto_mode), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (preview != null && platform == TargetPlatform.macOS) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(preview).create(recursive: true);
            await File('$preview/${brightness.name}-menu.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(model.switches.last, ('example.com:443', 'direct'));
        expect(find.text('切换为直连'), findsNothing);
      }
    }
    debugDefaultTargetPlatformOverride = null;
    debugDisableShadows = originalShadows;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('指定目标页签在窄窗口和明暗模式下可查看与移除', (tester) async {
    tester.view.physicalSize = const Size(592, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()..connected = true;
    kernel.appliedProfile = ProxyProfile(
      routesOverrides: 'proxy www.example.com\ndirect 2001:db8:0:0:0:0:0:1',
    );
    final model = _RoutingModel(proxy: kernel)..loading = false;
    addTearDown(model.dispose);
    model.dirty = true;
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(brightness),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: RoutesPage(model: model),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('指定目标 2'));
      await tester.tap(find.text('指定目标 2'));
      await tester.pumpAndSettle();
      expect(find.text('www.example.com'), findsOneWidget);
      expect(find.text('2001:db8:0:0:0:0:0:1'), findsOneWidget);
      await tester.ensureVisible(find.text('移除指定').last);
      await tester.tap(find.text('移除指定').last);
      await tester.pumpAndSettle();
      expect(model.switches.last, ('www.example.com:443', 'auto'));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('直连规则 0'));
      await tester.tap(find.text('直连规则 0'));
      await tester.pumpAndSettle();
    }
  });
  testWidgets('隧道路由允许编辑草稿时操作，离线或忙碌时禁用', (tester) async {
    final kernel = _Kernel()..connected = true;
    final model = _RoutingModel(proxy: kernel)..loading = false;
    addTearDown(model.dispose);
    kernel.publish([_tunnel('1', '[2001:db8::1]:443', 'direct', 'active')]);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (context, _) => TunnelsPage(model: model),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('tunnel-route-1'));
    for (final (label, route) in const [
      ('切换为代理', 'proxy'),
      ('切换为直连', 'direct'),
      ('恢复自动路由', 'auto'),
    ]) {
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(model.switches.last, ('[2001:db8::1]:443', route));
    }
    model.update(() => model.dirty = true);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复自动路由'));
    await tester.pumpAndSettle();
    expect(model.switches.last, ('[2001:db8::1]:443', 'auto'));
    model.update(() => model.working = true);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    kernel.connected = false;
    model.update(() => model.working = false);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNull);
  });
  testWidgets('概览与隧道列表统一统计代理、直连和解析中的请求，推送后同步更新', (tester) async {
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()..connected = true;
    // 内核的连接计数只包括代理流，不能用于所有业务隧道的总数。
    kernel.connections = const [
      ConnectionStatus(
        id: 'default',
        name: '默认连接',
        protocol: 'http3',
        activeTunnels: 1,
        pendingTunnels: 1,
      ),
    ];
    final model = ProxyViewModel(proxy: kernel, native: _Desktop())
      ..loading = false;
    addTearDown(model.dispose);
    final tunnels = [
      _tunnel('1', 'api.example.com:443', 'proxy', 'active'),
      _tunnel('2', 'direct.example.com:443', 'direct', 'active'),
      _tunnel('3', 'waiting.example.com:443', 'direct', 'pending'),
      _tunnel('4', 'dns.example.com:443', 'resolving', 'resolving'),
    ];
    kernel.publish(tunnels);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.light),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (context, _) => model.page == 0
                ? OverviewPage(model: model)
                : TunnelsPage(model: model),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final activeCount = find.byKey(const ValueKey('overview-active-tunnels'));
    final pendingCount = find.byKey(const ValueKey('overview-pending-tunnels'));
    expect(tester.widget<Text>(activeCount).data, '2');
    expect(tester.widget<Text>(pendingCount).data, '等待 2 · 查看');
    await tester.tap(activeCount);
    await tester.pumpAndSettle();
    expect(model.page, 4);
    expect(find.text('共 4 条 · 活跃 2 · 等待 2'), findsOneWidget);
    kernel.publish(tunnels.take(3).toList());
    await tester.pumpAndSettle();
    expect(find.text('共 3 条 · 活跃 2 · 等待 1'), findsOneWidget);
    model.navigate(0);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(activeCount).data, '2');
    expect(tester.widget<Text>(pendingCount).data, '等待 1 · 查看');
    kernel.publish([]);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(activeCount).data, '0');
    kernel.connected = false;
    kernel.publish([]);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(activeCount).data, '—');
  });

  testWidgets('隧道列表支持筛选搜索、实时移除，并检查桌面尺寸与系统明暗模式', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final kernel = _Kernel()..connected = true;
    final model = ProxyViewModel(proxy: kernel, native: _Desktop())
      ..loading = false;
    addTearDown(model.dispose);
    final tunnels = [
      _tunnel('1', 'api.example.com:443', 'proxy', 'active'),
      _tunnel(
        '2',
        '[2001:db8::1]:8080',
        'direct',
        'active',
        originalProtocol: 'udp',
      ),
      _tunnel(
        '3',
        'downloads.example.com:443',
        'proxy',
        'pending',
        originalProtocol: 'udp',
      ),
    ];
    kernel.publish(tunnels);
    final boundary = GlobalKey();
    final preview = Platform.environment['UI_TUNNELS_PREVIEW_DIR'];
    if (preview != null) {
      await tester.runAsync(() async {
        // 预览可读取本机系统字体，不将系统字体复制到项目或发布包。
        final latinFont = Platform.environment['UI_PREVIEW_LATIN_FONT'];
        if (latinFont != null) {
          await (FontLoader(DesktopDesign.fontFamily)..addFont(
                File(latinFont).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        for (final font in {
          DesktopDesign.fontFamily: 'assets/fonts/NotoSansSC-Variable.ttf',
          'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
    }
    Future<void> show(
      Brightness brightness,
      Size size,
      TargetPlatform platform,
    ) async {
      tester.view.physicalSize = size;
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: desktopTheme(brightness),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: ListenableBuilder(
                  listenable: model,
                  builder: (context, _) => TunnelsPage(model: model),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    model.dirty = true;
    for (final brightness in Brightness.values) {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        for (final size in [const Size(1120, 780), const Size(592, 430)]) {
          await show(brightness, size, platform);
          expect(find.text('api.example.com:443'), findsOneWidget);
          expect(find.text('[2001:db8::1]:8080'), findsOneWidget);
          expect(find.text('等待连接'), findsOneWidget);
          expect(find.text('原始协议'), findsOneWidget);
          expect(find.text('TCP'), findsOneWidget);
          expect(find.text('UDP'), findsNWidgets(3));
          final header = find.widgetWithText(TextButton, '目标地址');
          expect(tester.getSize(header).width, lessThan(120));
          expect(
            find.ancestor(of: header, matching: find.byType(Tooltip)),
            findsNothing,
          );
          await tester.tap(header);
          await tester.pumpAndSettle();
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: tester.getCenter(header));
          await mouse.moveTo(tester.getCenter(header));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 1));
          expect(find.textContaining('按目标地址'), findsNothing);
          if (preview != null && platform == TargetPlatform.macOS) {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await render.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(preview).create(recursive: true);
              await File(
                '$preview/${brightness.name}-${size.width.toInt()}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await mouse.removePointer();
        }
      }
    }
    await tester.enterText(
      find.byKey(const ValueKey('tunnel-search')),
      'downloads',
    );
    await tester.pumpAndSettle();
    expect(find.text('downloads.example.com:443'), findsOneWidget);
    expect(find.text('api.example.com:443'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('tunnel-search')), '');
    await tester.tap(find.text('全部路由'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '直连'));
    await tester.pumpAndSettle();
    expect(find.text('[2001:db8::1]:8080'), findsOneWidget);
    expect(find.text('api.example.com:443'), findsNothing);
    expect(find.text('共 3 条 · 活跃 2 · 等待 1 · 当前显示 1 条'), findsOneWidget);
    kernel.publish([]);
    await tester.pumpAndSettle();
    expect(find.text('暂无隧道'), findsOneWidget);
    kernel.connected = false;
    kernel.publish(tunnels);
    await tester.pumpAndSettle();
    expect(find.text('内核未连接，列表保留最后一次收到的隧道信息。'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
