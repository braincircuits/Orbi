import 'traffic_fixture.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class _PreviewModel extends ProxyViewModel {
  // 截图状态由用例设置，不读取磁盘配置或向真实内核发送请求。
  @override
  Future<void> initialize() async {
    loading = false;
  }

  @override
  Future<void> refreshOverview() async {}
}

/// 按需使用应用内字体导出共享桌面界面的预览图。
void main() {
  final destination = Platform.environment['UI_PREVIEW_DIR'];
  testWidgets('导出统一桌面界面浅色与深色预览', (tester) async {
    await tester.runAsync(() async {
      for (final entry in {
        'NotoSansSC': 'assets/fonts/NotoSansSC-Variable.ttf',
        'RobotoMono': 'assets/fonts/RobotoMono-Variable.ttf',
        'Lucide': 'assets/fonts/Lucide.ttf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(rootBundle.load(entry.value));
        await loader.load();
      }
      // 可选加载本机系统字体，仅用于截图，不复制或打包系统字体。
      for (final entry in {
        DesktopDesign.fontFamily: Platform.environment['UI_PREVIEW_LATIN_FONT'],
        'PingFang SC': Platform.environment['UI_PREVIEW_CJK_FONT'],
      }.entries) {
        if (entry.value == null) continue;
        final loader = FontLoader(
          entry.key,
        )..addFont(File(entry.value!).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
      final material = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await material.load();
    });
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('network-preview-'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method == 'environment') {
            return {'support': directory!.path, 'resources': directory.path};
          }
          return null;
        });
    tester.view.physicalSize = const Size(1120, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final model = _PreviewModel();
    addTearDown(model.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: NetworkApp(model: model),
      ),
    );
    await tester.pumpAndSettle();
    model.proxy.addLog('INFO 代理内核已就绪，等待请求');
    model.proxy.addLog('WARN 示例连接尚未配置，请填写服务端信息');
    model.proxy.addLog('INFO 本地监听地址：127.0.0.1:8080');
    Future<void> capture(String name) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = await Directory(destination!).create(recursive: true);
        await File('${folder.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      model.update(() {
        final profile = ProxyProfile(
          connections: List.generate(
            100,
            (i) => ConnectionProfile(
              id: 'node-$i',
              name: i == 0
                  ? '默认连接'
                  : i == 1
                  ? 'QUIC 连接'
                  : '连接 ${i + 1}',
              hasPassword: true,
              config: {
                'protocol': i.isEven ? 'http2' : 'http3',
                'server.host': i < 2
                    ? '2001:db8:1000:578c::82c'
                    : 'proxy-$i.example.com',
              },
            ),
          ),
          defaultConnectionId: 'node-0',
        );
        model.proxy.appliedProfile = profile;
        model.proxy.defaultConnectionId = profile.defaultConnectionId;
        model.proxy.connected = true;
        model.accept(profile);
      });
      for (final page in [
        '概览',
        '连接配置',
        '路由规则',
        '运行日志',
        '连接诊断',
        '活跃隧道',
      ].indexed) {
        await tester.tap(find.text(page.$2).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (page.$1 == 1) {
          await capture('${brightness.name}-connections-collapsed');
          await tester.tap(find.byKey(const ValueKey('edit-node-0')));
          await tester.pumpAndSettle();
          for (final key in ['configuration', 'connection-editor']) {
            final scrollable = find
                .descendant(
                  of: find.byKey(PageStorageKey(key)),
                  matching: find.byType(Scrollable),
                )
                .first;
            tester.state<ScrollableState>(scrollable).position.jumpTo(0);
            await tester.pumpAndSettle();
          }
        }
        await capture('${brightness.name}-${page.$1}');
        if (page.$1 == 1) {
          await tester.tap(find.text('列表'));
          await tester.pumpAndSettle();
          await capture('${brightness.name}-connections-list');
          tester.view.physicalSize = const Size(864, 642);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final apply = find.widgetWithText(FilledButton, '应用并保存');
          expect(tester.getRect(apply).bottom, lessThan(606));
          expect(tester.getRect(apply).right, greaterThan(600));
          await capture('${brightness.name}-connections-864');
          tester.view.physicalSize = const Size(1120, 780);
          await tester.pumpAndSettle();
          await tester.tap(find.text('卡片'));
          await tester.pumpAndSettle();
          final scrollable = find
              .descendant(
                of: find.byKey(const PageStorageKey('connection-editor')),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(
            find.byKey(const PageStorageKey('connection-parameters')),
            300,
            scrollable: scrollable,
          );
          ExpansibleController.of(tester.element(find.text('连接参数'))).expand();
          await tester.pumpAndSettle();
          final position = tester.state<ScrollableState>(scrollable).position;
          position.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture('${brightness.name}-advanced');
        }
      }
      await tester.tap(find.text('设置…'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('${brightness.name}-settings');
      await tester.tap(find.byTooltip('关闭设置（保留草稿）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('概览').first);
      model.update(() {
        final profile = ProxyProfile(
          values: {'server.host': 'proxy.example.com'},
        );
        model.proxy.appliedProfile = profile;
        model.proxy.defaultConnectionId = profile.defaultConnectionId;
        model.proxy.connections = [
          ConnectionStatus(
            id: profile.defaultConnectionId,
            name: profile.selected.name,
            protocol: profile.selected.protocol,
            activeTunnels: 0,
            pendingTunnels: 0,
          ),
        ];
        model.accept(profile);
        model.proxy.connected = true;
        model.proxy.running = false;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await capture('${brightness.name}-start-action');
      model.update(() {
        model.proxy.running = true;
        model.proxy.capabilities = {...model.proxy.capabilities, 'macosTun'};
        model.proxy.tunState = 'running';
        model.proxy.traffic = TrafficSnapshot.merge(
          null,
          trafficFixture(time: 300000),
        );
        model.proxy.address = '127.0.0.1:8080';
        model.proxy.connection = 'connected';
      });
      await tester.pumpAndSettle();
      await capture('${brightness.name}-running');
      final overviewScroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('overview')),
            matching: find.byType(Scrollable),
          )
          .first;
      final overviewPosition = tester
          .state<ScrollableState>(overviewScroll)
          .position;
      overviewPosition.jumpTo(overviewPosition.maxScrollExtent);
      await tester.pumpAndSettle();
      await capture('${brightness.name}-overview-tests');
      overviewPosition.jumpTo(0);
      await tester.pumpAndSettle();
      for (final size in [const Size(864, 642), const Size(1024, 658)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture('${brightness.name}-overview-${size.width.toInt()}');
      }
      tester.view.physicalSize = const Size(1120, 780);
      await tester.pumpAndSettle();
      model.update(() {
        model.loading = true;
        model.proxy.connected = false;
        model.proxy.running = false;
      });
      // 加载进度持续动画，导出当前帧而不是等待动画停止。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await capture('${brightness.name}-startup');
      model.update(() {
        model.loading = false;
        model.proxy.connected = true;
      });
      await tester.pumpAndSettle();
    }
    tester.view.physicalSize = const Size(720, 540);
    await tester.tap(find.text('概览').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture('dark-compact');
    for (final brightness in [Brightness.light, Brightness.dark]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      model.message('无法连接内核，请检查连接状态后重试。', failure: true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final message = find.byKey(const ValueKey('desktop-message'));
      expect(message, findsOneWidget);
      await capture('${brightness.name}-message');
      await tester.tap(
        find.descendant(of: message, matching: find.byType(IconButton)),
      );
      await tester.pumpAndSettle();
      expect(message, findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => directory!.delete(recursive: true));
  }, skip: destination == null);
}
