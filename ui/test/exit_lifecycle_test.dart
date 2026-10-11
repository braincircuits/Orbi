import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

class ExitModel extends ProxyViewModel {
  final result = Completer<bool>();
  int requests = 0;
  @override
  Future<void> initialize() async {
    loading = false;
  }

  @override
  Future<bool> prepareToExit() {
    requests++;
    return result.future;
  }
}

void main() {
  for (final allowed in [false, true]) {
    testWidgets('系统退出请求等待内核结果：允许退出=$allowed', (tester) async {
      tester.view.physicalSize = const Size(1120, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = ExitModel();
      await tester.pumpWidget(NetworkApp(model: model));
      final response = Completer<Object?>();
      unawaited(
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/platform',
          const JSONMethodCodec().encodeMethodCall(
            const MethodCall('System.requestAppExit'),
          ),
          (data) =>
              response.complete(const JSONMethodCodec().decodeEnvelope(data!)),
        ),
      );
      await tester.pump();
      expect(model.requests, 1);
      expect(response.isCompleted, isFalse);
      model.result.complete(allowed);
      await tester.pump();
      expect(await response.future, {'response': allowed ? 'exit' : 'cancel'});
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}
