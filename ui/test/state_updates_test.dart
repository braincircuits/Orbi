import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/widgets/desktop_select.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'traffic_fixture.dart';

class _Kernel extends ProxyController {
  final records = <String, DiagnosticOperation>{};
  int logReads = 0;
  @override
  List<KernelLog> get logs {
    logReads++;
    return super.logs;
  }

  @override
  Map<String, DiagnosticOperation> get operations => records;

  @override
  Future<String> resolveRoute(String target) async => 'route';

  void publish() => notifyListeners();
}

class _Model extends ProxyViewModel {
  _Model(_Kernel kernel) : super(proxy: kernel) {
    loading = false;
    accept(kernel.appliedProfile!);
  }

  final switches = <(String, String)>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> refreshOverview() async {}
  @override
  Future<bool> routeTarget(String target, String route) async {
    switches.add((target, route));
    return true;
  }
}

TunnelStatus _tunnel(String id, {String route = 'direct'}) => TunnelStatus(
  id: id,
  target: '$id.example.com:443',
  source: '127.0.0.1:50000',
  route: route,
  state: 'active',
  profileName: '',
  protocol: route == 'direct' ? 'tcp' : 'http2',
  originalProtocol: 'tcp',
  createdAt: DateTime(2026, 10, 14),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Kernel kernel;
  late _Model model;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (_) async => null);
    kernel = _Kernel()
      ..connected = true
      ..running = true
      ..appliedProfile = ProxyProfile();
    model = _Model(kernel);
  });
  tearDown(() {
    model.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, null);
  });

  test('相同快照不通知，流量、隧道、诊断只通知各自订阅者，控制变化仍更新主状态', () {
    var control = 0, traffic = 0, tunnels = 0, operations = 0, overview = 0;
    model.addListener(() => control++);
    model.trafficChanges.addListener(() => traffic++);
    model.tunnelChanges.addListener(() => tunnels++);
    model.operationChanges.addListener(() => operations++);
    model.overviewChanges.addListener(() => overview++);
    kernel.publish();
    expect(control, 0);
    kernel.tunnels = [_tunnel('a')];
    kernel.publish();
    expect(tunnels, 1);
    // 相同内容重新解析成新对象，不应触发列表刷新。
    kernel.tunnels = [_tunnel('a')];
    kernel.publish();
    expect(tunnels, 1);
    kernel.tunnels = [_tunnel('a', route: 'proxy')];
    kernel.publish();
    expect(tunnels, 2);
    kernel.traffic = TrafficSnapshot.merge(null, trafficFixture());
    kernel.publish();
    expect(traffic, 1);
    kernel.traffic = TrafficSnapshot.merge(
      kernel.traffic,
      trafficFixture(history: false),
    );
    kernel.publish();
    expect(traffic, 1);
    kernel.records['route'] = DiagnosticOperation.fromJson({
      'id': 'route',
      'state': 'succeeded',
      'stage': 'route',
      'elapsedMillis': 10,
    });
    kernel.publish();
    expect(operations, 1);
    expect(overview, 0);
    expect(control, 0);
    kernel.connected = false;
    kernel.publish();
    expect(control, 1);
    expect((traffic, tunnels, operations), (1, 2, 1));
  });

  test('连接计数变化不刷新连接选项，名称和协议变化仍通知页面', () {
    var notifications = 0;
    model.addListener(() => notifications++);
    void publish({
      int count = 0,
      String name = '默认连接',
      String protocol = 'http2',
    }) {
      kernel.connections = [
        ConnectionStatus(
          id: 'default',
          name: name,
          protocol: protocol,
          activeTunnels: count,
          pendingTunnels: 0,
        ),
      ];
      kernel.publish();
    }

    publish();
    expect(notifications, 1);
    publish(count: 10);
    expect(notifications, 1);
    publish(name: '另一个名称');
    expect(notifications, 2);
    publish(name: '另一个名称', protocol: 'http3');
    expect(notifications, 3);
  });

  testWidgets('隐藏的日志和隧道列表不响应推送，切回时显示最新数据且保留搜索', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    model.page = 3;
    kernel.addLog('INFO 匹配旧记录');
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('log-search')), '匹配');
    model.navigate(1);
    await tester.pumpAndSettle();
    var tables = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget.runtimeType.toString() == 'SortableTable') tables++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    kernel.logReads = 0;
    for (var i = 0; i < 5; i++) {
      kernel.tunnels = [_tunnel('latest-$i')];
      kernel.publish();
      kernel.addLog('INFO 匹配新记录 $i');
      await tester.pump();
    }
    expect(kernel.logReads, 0, reason: '隐藏日志不应重新过滤和构建');
    expect(tables, 0, reason: '隐藏隧道不应重新排序和构建表格');
    model.navigate(3);
    await tester.pumpAndSettle();
    expect(find.text('匹配新记录 4'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('log-search')))
          .controller!
          .text,
      '匹配',
    );
    model.navigate(4);
    await tester.pumpAndSettle();
    expect(find.text('latest-4.example.com:443'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('异步路由结果更新查询卡片和诊断记录，不刷新主页面或概览', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    model.page = 2;
    await model.queryRoute('example.com');
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    var unrelatedBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, _) {
      if ([
        'ProxyHome',
        'OverviewPage',
        'RoutesPage',
      ].contains(element.widget.runtimeType.toString())) {
        unrelatedBuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    kernel.records['route'] = DiagnosticOperation.fromJson({
      'id': 'route',
      'state': 'succeeded',
      'stage': 'routing',
      'elapsedMillis': 10,
      'result': {'action': 'direct', 'matchedBy': 'direct_rule'},
    });
    kernel.publish();
    await tester.pump();
    expect(find.text('直接连接 · 命中域名或地址直连规则'), findsOneWidget);
    expect(unrelatedBuilds, 0);
    model.navigate(5);
    await tester.pumpAndSettle();
    expect(find.text('直接连接 · 域名或地址规则'), findsOneWidget);
    unrelatedBuilds = 0;
    kernel.records['route'] = DiagnosticOperation.fromJson({
      'id': 'route',
      'state': 'failed',
      'stage': 'routing',
      'elapsedMillis': 20,
      'result': {'code': 'TEST', 'message': '测试诊断错误'},
    });
    kernel.publish();
    await tester.pump();
    expect(find.text('测试诊断错误\n错误代码：TEST'), findsOneWidget);
    expect(unrelatedBuilds, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('连续状态推送更新计数和速率，不重建主页面、隐藏页面与筛选框', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    final rebuilt = <String, int>{};
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, _) {
      final type = element.widget.runtimeType.toString();
      rebuilt.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    for (var i = 1; i <= 10; i++) {
      kernel.tunnels = [for (var j = 0; j < i; j++) _tunnel('$j')];
      kernel.traffic = TrafficSnapshot.merge(kernel.traffic, {
        ...trafficFixture(time: i * 1000, history: false),
        'sendBytesPerSecond': i * 1024.0,
      });
      kernel.publish();
      await tester.pump();
    }
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('overview-active-tunnels')))
          .data,
      '10',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('overview-send-rate')))
          .data,
      '10.2 KB/s',
    );
    for (final type in [
      'ProxyHome',
      'OverviewPage',
      'ConfigurationPage',
      'RoutesPage',
      'TunnelsPage',
      'DiagnosticsPage',
      'LogsPage',
      'DesktopSelect<String>',
    ]) {
      expect(rebuilt[type] ?? 0, 0, reason: '$type 不应被高频状态刷新');
    }
    model.navigate(4);
    await tester.pumpAndSettle();
    expect(find.text('共 10 条 · 活跃 10 · 等待 0'), findsOneWidget);
    rebuilt.clear();
    kernel.tunnels = [_tunnel('last')];
    kernel.publish();
    await tester.pump();
    expect(find.text('last.example.com:443'), findsOneWidget);
    expect(find.text('共 1 条 · 活跃 1 · 等待 0'), findsOneWidget);
    expect(rebuilt['ProxyHome'] ?? 0, 0);
    expect(rebuilt['TunnelsPage'] ?? 0, 0);
    expect(rebuilt['DesktopSelect<String>'] ?? 0, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('筛选点击跨越状态刷新仍生效，隧道重排保留已打开菜单对应的目标', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    model.page = 4;
    kernel.tunnels = [_tunnel('a'), _tunnel('b')];
    kernel.publish();
    await tester.pumpWidget(NetworkApp(model: model));
    await tester.pumpAndSettle();
    final filter = find.byType(DesktopSelect<String>);
    await tester.tap(find.descendant(of: filter, matching: find.text('全部路由')));
    await tester.pumpAndSettle();
    final option = find.widgetWithText(MenuItemButton, '直连').hitTestable();
    final gesture = await tester.startGesture(
      tester.getCenter(option),
      kind: PointerDeviceKind.mouse,
    );
    kernel.tunnels = [_tunnel('a'), _tunnel('b'), _tunnel('c', route: 'proxy')];
    kernel.publish();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<DesktopSelect<String>>(filter).value, 'direct');
    expect(find.text('共 3 条 · 活跃 3 · 等待 0 · 当前显示 2 条'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tunnel-route-a')));
    await tester.pumpAndSettle();
    kernel.tunnels = [_tunnel('b'), _tunnel('a')];
    kernel.publish();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '切换为代理'));
    await tester.pumpAndSettle();
    expect(model.switches, [('a.example.com:443', 'proxy')]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
