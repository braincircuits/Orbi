import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/connection_document.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/configuration_transfer.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

Map<String, dynamic> document({bool password = false}) => {
  'version': 1,
  'kind': 'network-connections',
  'connections': [
    {
      'name': '连接甲',
      'config': {
        'server.host': 'new.example',
        'protocol': 'http2',
        if (password) 'password': '文件密码',
      },
    },
  ],
};

class TransferDesktop extends TestDesktop {
  TransferDesktop() : super(Directory.systemTemp);
  final saved = <Map<String, dynamic>>[];
  @override
  Future<String?> exportDocument(String name, String text) async {
    saved.add(jsonDecode(text) as Map<String, dynamic>);
    return name;
  }
}

class TransferKernel extends TestKernel {
  final exports = <(List<String>, bool)>[];
  final previews = <(String, int)>[];
  final imports = <(String, int)>[];
  @override
  Future<Map<String, dynamic>> exportConnections(
    List<String> ids,
    bool includePassword,
  ) async {
    exports.add((ids, includePassword));
    return document(password: includePassword);
  }

  @override
  Future<Map<String, dynamic>> previewRouting(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) async {
    previews.add((strategy, revision));
    return document;
  }

  @override
  Future<int> importRouting(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) async {
    imports.add((strategy, revision));
    final next = ProxyProfile.fromKernel(appliedProfile!.runtimeConfiguration)
      ..rules = document['directRules'] as String;
    publish(next, revision + 1);
    return revision + 1;
  }
}

class TransferModel extends ProxyViewModel {
  TransferModel({required super.proxy, required super.native});
  Map<String, dynamic>? incoming;
  @override
  Future<Map<String, dynamic>?> readConfigurationDocument() async => incoming;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('连接文件严格校验，新增不继承密码，明确覆盖才保留原密码', () {
    final current = [
      ConnectionProfile(
        id: 'a',
        name: '连接甲',
        hasPassword: true,
        config: {'server.host': 'old.example', 'password': '原密码'},
      ),
    ];
    final incoming = ConnectionDocument.parse(document());
    final added = ConnectionDocument.merge(current, incoming, [null], 'new');
    expect(added.length, 2);
    expect(added.last.id, 'new-0');
    expect(added.last.name, '连接甲（导入 1）');
    expect(added.last.values['password'], isEmpty);
    expect(added.last.hasPassword, isFalse);
    final replaced = ConnectionDocument.merge(current, incoming, ['a'], 'new');
    expect(replaced.single.id, 'a');
    expect(replaced.single.values['password'], '原密码');
    expect(replaced.single.hasPassword, isTrue);
    final provided = ConnectionDocument.merge(
      current,
      ConnectionDocument.parse(document(password: true)),
      ['a'],
      'new',
    );
    expect(provided.single.values['password'], '文件密码');
    expect(current.single.values['server.host'], 'old.example');
    expect(
      () => ConnectionDocument.merge(
        current,
        [...incoming, ...incoming],
        ['a', 'a'],
        'new',
      ),
      throwsStateError,
    );
    expect(
      () => ConnectionDocument.parse({...document(), 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => ConnectionDocument.parse({
        ...document(),
        'local': <String, dynamic>{},
      }),
      throwsFormatException,
    );
    final invalid = document();
    ((invalid['connections'] as List).first as Map)['id'] = 'a';
    expect(() => ConnectionDocument.parse(invalid), throwsFormatException);
  });

  late TransferKernel kernel;
  late TransferDesktop desktop;
  late TransferModel model;
  setUp(() {
    kernel = TransferKernel()
      ..publish(
        ProxyProfile(
          defaultConnectionId: 'a',
          connections: [
            ConnectionProfile(
              id: 'a',
              name: '连接甲',
              hasPassword: true,
              config: {'server.host': 'old.example'},
            ),
            ConnectionProfile(
              id: 'b',
              name: '连接乙',
              hasPassword: true,
              config: {'server.host': 'second.example'},
            ),
          ],
        ),
        3,
      );
    desktop = TransferDesktop();
    model = TransferModel(proxy: kernel, native: desktop)..loading = false;
    model.accept(kernel.appliedProfile!);
  });
  tearDown(() => model.dispose());

  Future<void> show(WidgetTester tester, bool routes) async {
    tester.view.physicalSize = const Size(480, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: desktopTheme(Brightness.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (context, _) =>
                ConfigurationTransfer(model: model, routes: routes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('导出可选单个或全部，默认不含密码，取消不写文件', (tester) async {
    await show(tester, false);
    await tester.tap(find.text('导出连接'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '包含密码'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(desktop.saved, isEmpty);
    await tester.tap(find.text('导出连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接乙'));
    await tester.tap(find.text('包含密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出文件'));
    await tester.pumpAndSettle();
    expect(kernel.exports.single.$1, ['a']);
    expect(kernel.exports.single.$2, isTrue);
    expect(desktop.saved.single.toString(), contains('文件密码'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接导入进入草稿，缺密码可补填，默认连接和其他配置保留', (tester) async {
    model.incoming = document();
    await show(tester, false);
    await tester.tap(find.text('导入连接'));
    await tester.pumpAndSettle();
    expect(find.text('文件未包含密码'), findsOneWidget);
    await tester.tap(find.text('导入草稿'));
    await tester.pumpAndSettle();
    expect(model.connectionDrafts.length, 3);
    expect(model.defaultId, 'a');
    expect(model.dirty, isTrue);
    expect(model.connectionDrafts.last.hasPassword, isFalse);
    expect(kernel.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('路由先校验预览，取消无变更，整体替换确认后保存', (tester) async {
    model.incoming = {
      'version': 2,
      'kind': 'network-routes',
      'directRules': '# 备注\nnew.example',
      'targetRoutes': <String, dynamic>{},
    };
    await show(tester, true);
    await tester.tap(find.text('导入路由文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    expect(kernel.previews.single, ('merge', 3));
    expect(kernel.imports, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(kernel.imports, isEmpty);
    await tester.tap(find.text('导入路由文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整体替换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(kernel.imports.single, ('replace', 3));
    expect(model.rules.text, '# 备注\nnew.example');
    expect(model.defaultId, 'a');
    expect(model.dirty, isFalse);
    expect(tester.takeException(), isNull);
  });
}
