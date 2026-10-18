import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'overview_test.dart' show OverviewApi, fixture;

class _ShutdownApi extends OverviewApi {
  late File endpoint;
  final stopRequested = Completer<void>();
  bool failShutdown = false;

  @override
  Future<Map<String, dynamic>> request(
    Uri base,
    String token,
    String method,
    String path, {
    Object? body,
    int? expectedRevision,
  }) async {
    if (path == 'kernel/shutdown') {
      calls.add('$method $path');
      if (failShutdown) throw StateError('测试内核退出失败');
      await endpoint.delete();
      return {
        'data': {'stopping': true},
      };
    }
    final response = await super.request(
      base,
      token,
      method,
      path,
      body: body,
      expectedRevision: expectedRevision,
    );
    if (path == 'tun/stop' && !stopRequested.isCompleted) {
      stopRequested.complete();
    }
    return response;
  }
}

void main() {
  for (final failure in ['tun/stop', 'kernel/shutdown']) {
    test('$failure 失败取消退出后恢复真实 SSE 状态更新', () async {
      final api = _ShutdownApi()
        ..failTunStop = failure == 'tun/stop'
        ..failShutdown = failure == 'kernel/shutdown';
      final (directory, _, proxy) = await fixture(client: api);
      api.endpoint = proxy.endpointFile;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connections = StreamController<HttpResponse>();
      final events = StreamIterator(connections.stream);
      server.listen((request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(': 已连接\n\n');
        await request.response.flush();
        connections.add(request.response);
      });
      try {
        final discovery =
            jsonDecode(await proxy.endpointFile.readAsString()) as Map;
        discovery['url'] = 'http://127.0.0.1:${server.port}';
        await proxy.endpointFile.writeAsString(jsonEncode(discovery));
        await proxy.attach();
        proxy.subscribe();
        expect(
          await events.moveNext().timeout(const Duration(seconds: 3)),
          isTrue,
        );
        await expectLater(proxy.shutdown(), throwsStateError);
        expect(
          await events.moveNext().timeout(const Duration(seconds: 3)),
          isTrue,
        );
        final changed = Completer<void>();
        proxy.addListener(() {
          if (proxy.routingMode == 'direct' && !changed.isCompleted) {
            changed.complete();
          }
        });
        api.mode = 'direct';
        final status = await api.request(Uri(), '', 'GET', 'status');
        events.current.write(
          'event: status\ndata: ${jsonEncode(status['data'])}\n\n',
        );
        await events.current.flush();
        await changed.future.timeout(const Duration(seconds: 3));
        expect(proxy.streaming, isTrue);
        expect(await proxy.endpointFile.exists(), isTrue);
      } finally {
        proxy.dispose();
        await events.cancel();
        await connections.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    });
  }

  test('退出主动停止实际 TUN，会话结束前不关闭内核，状态缓存可滞后', () async {
    final api = _ShutdownApi()..delayTunStop = true;
    final (directory, _, proxy) = await fixture(client: api);
    api.endpoint = proxy.endpointFile;
    api.tunState = 'running';
    expect(proxy.tunState, 'off');
    var completed = false;
    final closing = proxy.shutdown().then((_) => completed = true);
    try {
      await api.stopRequested.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(api.calls, isNot(contains('POST kernel/shutdown')));
      expect(await proxy.endpointFile.exists(), isTrue);
      api.tunState = 'off';
      await closing.timeout(const Duration(seconds: 2));
      expect(
        api.calls.indexOf('POST tun/stop'),
        lessThan(api.calls.indexOf('POST kernel/shutdown')),
      );
      expect(proxy.canShutdown, isFalse);
    } finally {
      api.tunState = 'off';
      await closing;
      proxy.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('TUN 清理失败时取消内核退出并保留重试能力', () async {
    final api = _ShutdownApi()..delayTunStop = true;
    final (directory, _, proxy) = await fixture(client: api);
    api.endpoint = proxy.endpointFile;
    api.tunState = 'running';
    final closing = proxy.shutdown();
    final rejected = expectLater(closing, throwsStateError);
    try {
      await api.stopRequested.future;
      api.tunState = 'failed';
      api.tunError = '测试路由清理失败';
      await rejected;
      expect(api.calls, isNot(contains('POST kernel/shutdown')));
      expect(proxy.canShutdown, isTrue);
      expect(await proxy.endpointFile.exists(), isTrue);
      api.delayTunStop = false;
      await proxy.shutdown();
      expect(proxy.canShutdown, isFalse);
    } finally {
      proxy.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('TUN 停止命令失败时保留内核和发现文件', () async {
    final api = _ShutdownApi()..failTunStop = true;
    final (directory, _, proxy) = await fixture(client: api);
    api.endpoint = proxy.endpointFile;
    try {
      await expectLater(proxy.shutdown(), throwsStateError);
      expect(api.calls, isNot(contains('POST kernel/shutdown')));
      expect(await proxy.endpointFile.exists(), isTrue);
      expect(proxy.canShutdown, isTrue);
    } finally {
      proxy.dispose();
      await directory.delete(recursive: true);
    }
  });
}
