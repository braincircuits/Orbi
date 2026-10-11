import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

class RoutingKernel extends TestKernel {
  bool failRoute = false;
  bool externalChange = false;

  @override
  Future<int> routeTarget(
    String target,
    String route, {
    int? expectedRevision,
  }) async {
    expect(expectedRevision, configurationRevision);
    if (failRoute) throw StateError('测试路由切换失败');
    final previous = appliedProfile!;
    final routes = {...previous.targetRoutes};
    if (route == 'auto') {
      routes.remove(target);
    } else {
      routes[target] = route;
    }
    final appliedRevision = configurationRevision + 1;
    publish(
      ProxyProfile(
        values: previous.values,
        connections: previous.connections.map((c) => c.copy()).toList(),
        defaultConnectionId: previous.defaultConnectionId,
        rules: previous.rules,
        routesFile: previous.routesFile,
        inlineRules: previous.inlineRules,
        routesOverrides: routes.entries
            .map((e) => '${e.value} ${e.key}')
            .join('\n'),
      ),
      appliedRevision,
    );
    if (externalChange) {
      publish(
        ProxyProfile(values: {'server.host': 'external.example'}),
        appliedRevision + 1,
      );
    }
    return appliedRevision;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RoutingKernel kernel;
  late ProxyViewModel model;
  setUp(() {
    kernel = RoutingKernel()
      ..publish(ProxyProfile(routesOverrides: 'proxy example.com'), 1);
    model = ProxyViewModel(
      proxy: kernel,
      native: TestDesktop(Directory.systemTemp),
    )..loading = false;
    model.accept(kernel.appliedProfile!);
    model.connectionName.text = '草稿连接';
    model.fields['password']!.text = '草稿密码';
    model.fields['port']!.text = '8888';
    model.rules.text = 'draft.example';
    model.routesFile.text = '/tmp/草稿规则.txt';
    model.inlineRules = false;
    model.changed('');
    model.addConnection();
    model.defaultId = model.editingId;
  });
  tearDown(() => model.dispose());

  test('目标路由单独保存，保留所有草稿及草稿默认连接，应用时保留最新路由', () async {
    final editing = model.editingId;
    await model.routeTarget('example.com', 'direct');
    expect(kernel.writes, isEmpty);
    expect(model.dirty, isTrue);
    expect(model.baseRevision, 2);
    expect(model.editingId, editing);
    expect(model.defaultId, editing);
    expect(model.connectionDrafts.length, 2);
    expect(model.connectionDrafts.first.name, '草稿连接');
    expect(model.connectionDrafts.first.values['password'], '草稿密码');
    expect(model.fields['port']!.text, '8888');
    expect(model.rules.text, 'draft.example');
    expect(model.routesFile.text, '/tmp/草稿规则.txt');
    expect(model.inlineRules, isFalse);
    expect(kernel.appliedProfile!.connections.length, 1);
    expect(kernel.appliedProfile!.selected.name, '默认连接');
    expect(kernel.appliedProfile!.values['port'], '8080');
    await model.apply();
    expect(kernel.appliedProfile!.targetRoutes, {'example.com': 'direct'});
    expect(kernel.appliedProfile!.defaultConnectionId, editing);
    expect(model.dirty, isFalse);
  });

  test('恢复自动立即保存并保留草稿，丢弃草稿不会恢复旧目标路由', () async {
    await model.routeTarget('example.com', 'auto');
    expect(model.draftProfile().targetRoutes, isEmpty);
    expect(model.dirty, isTrue);
    model.discardDrafts();
    expect(model.dirty, isFalse);
    expect(model.draftProfile().targetRoutes, isEmpty);
    expect(model.connectionDrafts.length, 1);
  });

  test('路由写入失败保留草稿及版本', () async {
    kernel.failRoute = true;
    await model.routeTarget('example.com', 'direct');
    expect(model.baseRevision, 1);
    expect(model.draftProfile().targetRoutes, {'example.com': 'proxy'});
    expect(model.connectionDrafts.first.values['password'], '草稿密码');
    expect(model.dirty, isTrue);
    expect(kernel.writes, isEmpty);
  });

  test('并发外部配置变更仍以内核为准，不保存错误版本', () async {
    kernel.externalChange = true;
    await model.routeTarget('example.com', 'direct');
    expect(model.baseRevision, 3);
    expect(model.fields['server.host']!.text, 'external.example');
    expect(model.dirty, isFalse);
    expect(kernel.writes, isEmpty);
  });
}
