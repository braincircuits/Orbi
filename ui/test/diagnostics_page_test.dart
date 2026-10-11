import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/diagnostics_page.dart';

import 'view_model_test.dart' show TestDesktop;

class DiagnosticKernel extends ProxyController {
  final records = <String, DiagnosticOperation>{};
  @override
  Map<String, DiagnosticOperation> get operations => records;
}

DiagnosticOperation operation(
  String id, {
  String? kind,
  String state = 'succeeded',
  Map<String, Object> result = const {},
}) => DiagnosticOperation.fromJson({
  'id': id,
  'state': state,
  'stage': kind ?? 'connect',
  'elapsedMillis': 120,
  'context': {'kind': ?kind},
  'result': result,
  'stages': [
    {'stage': kind ?? 'connect', 'elapsedMillis': 0},
  ],
});
void main() {
  testWidgets('概览检测不混入诊断，手动测试和路由结果正常显示且取消不等待', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'network-diagnostic-ui-',
    );
    final kernel = DiagnosticKernel();
    for (final kind in ['exit-ip', 'latency', 'websites']) {
      kernel.records[kind] = operation(kind, kind: kind);
    }
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory))
      ..loading = false;
    addTearDown(() {
      model.dispose();
      directory.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> show() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: desktopTheme(Brightness.light),
          home: Scaffold(body: DiagnosticsPage(model: model)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    expect(find.text('尚无诊断记录'), findsOneWidget);
    expect(find.textContaining('exit-ip'), findsNothing);
    expect(find.textContaining('latency'), findsNothing);
    expect(find.text('等待诊断结果'), findsNothing);
    kernel.records['route'] = operation(
      'route',
      result: {'action': 'direct', 'matchedBy': 'direct_rule'},
    );
    kernel.records['connection'] = operation(
      'connection',
      result: {'tunnelEstablished': true, 'target': 'example.com:443'},
    );
    await show();
    expect(find.text('尚无诊断记录'), findsNothing);
    expect(find.text('直接连接 · 域名或地址规则'), findsOneWidget);
    expect(find.text('代理认证通过，已建立到 example.com:443 的 TCP 隧道'), findsOneWidget);
    kernel.records.clear();
    kernel.records['cancelled'] = operation('cancelled', state: 'cancelled');
    await show();
    expect(find.text('诊断已取消'), findsOneWidget);
    expect(find.text('等待诊断结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
