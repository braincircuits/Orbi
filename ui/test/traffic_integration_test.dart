import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';

void main() {
  final jar = Platform.environment['UI_TEST_JAR'];
  final java = Platform.environment['UI_TEST_JAVA'];
  final resources = Platform.environment['UI_TEST_RESOURCES'];
  test(
    '真实内核流量采样经 HTTP 与 SSE 同步，界面重连恢复历史，启停保持正确口径',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-traffic-ui-',
      );
      final proxy = ProxyController(directory: directory);
      final observer = ProxyController(directory: directory);
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final remotes = <Socket>[];
      final subscription = origin.listen((socket) {
        remotes.add(socket);
        socket.listen(socket.add, onDone: socket.destroy);
      });
      Future<void> until(bool Function() predicate) async {
        for (var i = 0; i < 100; i++) {
          if (predicate()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        throw StateError('等待流量状态超时：${proxy.error}');
      }

      Socket? browser;
      try {
        await proxy.start(
          ProxyProfile(
            values: {
              'server.host': 'proxy.example',
              'password': '流量测试密码',
              'port': '0',
            },
            routingMode: 'direct',
            javaPath: java ?? '',
            jarPath: jar ?? '',
          ),
          resources ?? '',
        );
        await until(() => proxy.streaming);
        final session = proxy.traffic!.sessionId;
        final address = proxy.address.split(':');
        browser = await Socket.connect(address.first, int.parse(address.last));
        final bytes = <int>[];
        final payload = List<int>.generate(32768, (i) => i % 251);
        final received = Completer<void>();
        var sent = false;
        browser.listen((chunk) {
          bytes.addAll(chunk);
          if (!sent) {
            final header = latin1.decode(bytes);
            if (!header.contains('\r\n\r\n')) return;
            expect(header.startsWith('HTTP/1.1 200'), isTrue);
            bytes.clear();
            sent = true;
            browser!.add(payload);
          } else if (bytes.length == payload.length && !received.isCompleted) {
            received.complete();
          }
        });
        browser.write(
          'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\nHost: localhost\r\n\r\n',
        );
        await received.future.timeout(const Duration(seconds: 8));
        expect(bytes, payload);
        await until(
          () => proxy.traffic?.current.receivedBytes == payload.length,
        );
        expect(proxy.traffic!.current.sentBytes, payload.length);
        expect(proxy.traffic!.current.sendBytesPerSecond, greaterThan(0));
        expect(await observer.attach(), isTrue);
        expect(observer.traffic!.sessionId, session);
        expect(observer.traffic!.current.receivedBytes, payload.length);
        await proxy.stop();
        expect(proxy.traffic!.current.receivedBytes, payload.length);
        expect(proxy.traffic!.current.receiveBytesPerSecond, 0);
        expect(proxy.traffic!.sessionId, session);
        final records = await proxy.accessHistory();
        expect(records.items.single.host, '127.0.0.1');
        expect(records.items.single.connectionCount, 1);
        expect(records.items.single.lastFailureAt, 0);
        final profile = proxy.appliedProfile!;
        await proxy.shutdown();
        await proxy.connect(profile, resources ?? '');
        expect(proxy.traffic!.sessionId, '');
        expect(proxy.traffic!.current.receivedBytes, 0);
        expect(
          (await proxy.accessHistory()).items.single.host,
          records.items.single.host,
        );
        final summary = await proxy.trafficSummary(hourly: false);
        expect(summary.sentBytes, payload.length);
        expect(summary.receivedBytes, payload.length);
        expect(summary.recordCount, greaterThanOrEqualTo(1));
        expect(
          summary.buckets.fold<int>(0, (sum, b) => sum + b.sentBytes),
          payload.length,
        );
        expect((await proxy.trafficSummary()).interval, 'hour');
        await proxy.start(
          proxy.appliedProfile!,
          resources ?? '',
          applyDraft: false,
        );
        expect(proxy.traffic!.sessionId, isNot(session));
        expect(proxy.traffic!.current.sentBytes, 0);
      } finally {
        browser?.destroy();
        for (final socket in remotes) {
          socket.destroy();
        }
        await subscription.cancel();
        await origin.close();
        observer.dispose();
        if (proxy.canShutdown) await proxy.shutdown();
        proxy.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: resources == null && (jar == null || java == null)
        ? '需指定应用资源目录，或 JAR 和 Java 运行时'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
