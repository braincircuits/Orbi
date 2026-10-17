import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/tun_engine.dart';
import 'package:network_ui/services/runtime_preferences.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop, TestKernel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secret = 'unregistered-password-and-token';
  for (final (index, content) in [
    '{"password":"$secret","javaPath":',
    '{"tunEngine":"$secret"}',
  ].indexed) {
    test('启动设置解析失败不回显原文：$index', () async {
      final directory = await Directory.systemTemp.createTemp(
        'preferences-security-',
      );
      final file = File('${directory.path}/ui.json');
      final kernel = TestKernel();
      final model = ProxyViewModel(
        proxy: kernel,
        native: TestDesktop(directory),
      );
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      try {
        await file.writeAsString(content);
        await expectLater(
          RuntimePreferences().read(directory),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              '不含敏感原文',
              isNot(contains(secret)),
            ),
          ),
        );
        await model.initialize();
        await Future<void>.delayed(Duration.zero);
        expect(messages.single.failure, isTrue);
        expect(messages.single.text, isNot(contains(secret)));
        expect(await file.readAsString(), content);
      } finally {
        await subscription.cancel();
        model.dispose();
        await directory.delete(recursive: true);
      }
    });
  }
  test('非法 TUN 组件不将任意输入带入异常', () {
    expect(
      () => TunEngine.parse(secret),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          '不含敏感输入',
          isNot(contains(secret)),
        ),
      ),
    );
  });
}
