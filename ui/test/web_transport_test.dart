import 'traffic_fixture.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/services/kernel_api_client.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'view_model_test.dart' show TestDesktop;

void main() {
  for (final timing in ['请求前', '请求期间', '仍有发现文件']) {
    test('内核断线退出：$timing，按发现文件判断能否退出客户端', () async {
      final directory = await Directory.systemTemp.createTemp('network-exit-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final controller = ProxyController(directory: directory);
      final desktop = TestDesktop(directory);
      final model = ProxyViewModel(proxy: controller, native: desktop)
        ..loading = false;
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      var exits = 0;
      server.listen((request) async {
        if (request.uri.path.endsWith('/kernel/shutdown')) {
          exits++;
          await controller.endpointFile.delete();
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.write('{');
        await request.response.close();
      });
      try {
        await controller.endpointFile.parent.create(recursive: true);
        await controller.endpointFile.writeAsString(
          jsonEncode({
            'url': 'http://127.0.0.1:${server.port}',
            'token': 'test-only-token-012345678901234567890',
            'apiVersion': 1,
          }),
        );
        // 模拟连接失败后仍缓存着已校验地址与令牌。
        await expectLater(
          controller.attach(),
          throwsA(isA<KernelApiException>()),
        );
        expect(controller.canShutdown, isTrue);
        controller.running = true;
        final database = File(controller.configPath);
        await database.writeAsBytes([0, 1, 2, 3]);
        if (timing != '请求期间') await server.close(force: true);
        if (timing == '请求前') await controller.endpointFile.delete();

        final allowed = await model.prepareToExit();
        expect(allowed, timing != '仍有发现文件');
        expect(exits, timing == '请求期间' ? 1 : 0);
        expect(await database.readAsBytes(), [0, 1, 2, 3]);
        if (allowed) {
          expect(controller.canShutdown, isFalse);
          expect(controller.connected, isFalse);
          expect(controller.running, isFalse);
          expect(controller.streaming, isFalse);
          expect(controller.error, isEmpty);
          expect(messages, isEmpty);
          expect(desktop.windowShows, 0);
          // 重复退出也不再访问旧地址。
          expect(await model.prepareToExit(), isTrue);
        } else {
          expect(controller.canShutdown, isTrue);
          expect(await controller.endpointFile.exists(), isTrue);
          expect(messages.single.text, contains('尚不能确认内核已退出'));
          expect(messages.single.text, isNot(contains('SocketException')));
          expect(desktop.windowShows, 1);
        }
      } finally {
        await subscription.cancel();
        model.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    });
  }

  test('状态 JSON 损坏后仍可通过已校验的管理地址显式退出内核', () async {
    final directory = await Directory.systemTemp.createTemp('network-recover-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final controller = ProxyController(directory: directory);
    const token = 'test-only-token-012345678901234567890';
    var exits = 0, infoReads = 0;
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer $token',
      );
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/info')) {
        infoReads++;
        request.response.write('{"revision":\u0000}');
      } else if (request.uri.path.endsWith('/kernel/shutdown')) {
        expect(request.method, 'POST');
        exits++;
        await controller.endpointFile.delete();
        request.response.write('{"data":{"stopping":true}}');
      } else {
        fail('收到意外的管理请求');
      }
      await request.response.close();
    });
    try {
      await controller.endpointFile.parent.create(recursive: true);
      await controller.endpointFile.writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:${server.port}',
          'token': token,
          'apiVersion': 1,
        }),
      );
      await expectLater(
        controller.attach(),
        throwsA(isA<KernelApiException>()),
      );
      expect(controller.connected, isFalse);
      expect(controller.canShutdown, isTrue);
      expect(exits, 0);
      await controller.shutdown();
      expect(exits, 1);
      expect(infoReads, 1);
      expect(controller.canShutdown, isFalse);
    } finally {
      controller.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('内核仅确认收到退出请求却未完成退出时报告超时，保留重试能力', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-exit-timeout-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final controller = ProxyController(directory: directory);
    var finishShutdown = false;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/kernel/shutdown')) {
        if (finishShutdown) await controller.endpointFile.delete();
        request.response.write('{"data":{"stopping":true}}');
      } else {
        request.response.write('{');
      }
      await request.response.close();
    });
    try {
      await controller.endpointFile.parent.create(recursive: true);
      await controller.endpointFile.writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:${server.port}',
          'token': 'test-only-token-012345678901234567890',
          'apiVersion': 1,
        }),
      );
      await expectLater(
        controller.attach(),
        throwsA(isA<KernelApiException>()),
      );
      await expectLater(controller.shutdown(), throwsA(isA<StateError>()));
      expect(controller.error, contains('等待内核退出超时'));
      expect(controller.canShutdown, isTrue);
      finishShutdown = true;
      await controller.shutdown();
      expect(controller.canShutdown, isFalse);
    } finally {
      controller.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('SSE 按帧解析多行数据、断线续传、快照补齐并同步内核配置版本', () async {
    final directory = await Directory.systemTemp.createTemp('network-sse-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final controller = ProxyController(directory: directory);
    const token = 'test-only-token-012345678901234567890';
    var subscriptions = 0, configReads = 0, logReads = 0;
    var revision = 1;
    final resumed = Completer<String?>();
    final checks = <bool>[];
    final streams = <HttpResponse>[];
    Map<String, Object> status(int tunnels) => {
      'revision': revision,
      'running': true,
      'traffic': trafficFixture(),
      'historyStorage': {'pendingRecords': 0, 'droppedRecords': 0, 'error': ''},
      'connection': 'connected',
      'defaultConnectionId': 'one',
      'address': '127.0.0.1:8080',
      'connections': [
        {
          'id': 'one',
          'name': '测试',
          'protocol': 'http3',
          'activeTunnels': tunnels,
          'pendingTunnels': 0,
        },
      ],
      'tunnels': [
        for (var i = 0; i < tunnels; i++)
          {
            'id': 'tunnel-$i',
            'target': 'example.test:443',
            'source': '127.0.0.1:50000',
            'route': 'proxy',
            'state': 'active',
            'profileName': '测试',
            'protocol': 'http3',
            'createdAt': 1000,
          },
      ],
    };
    server.listen((request) async {
      checks.add(
        request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer $token' &&
            !request.uri.toString().contains(token),
      );
      Object data = {};
      final path = request.uri.path;
      if (path.endsWith('/events')) {
        subscriptions++;
        final response = request.response;
        streams.add(response);
        response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        response.bufferOutput = false;
        if (subscriptions == 1) {
          response.write(
            ': 心跳\r\nid: 10\r\nevent: status\r\ndata: {"running":true,\r\ndata: "traffic":${jsonEncode(trafficFixture())},"historyStorage":{"pendingRecords":0,"droppedRecords":0,"error":""},"revision":1,"connections":[{"activeTunnels":3}]}\r\n',
          );
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          response.write('\r\n');
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await response.close();
        } else {
          if (!resumed.isCompleted) {
            resumed.complete(request.headers.value('Last-Event-ID'));
          }
          revision = 2;
          response.write(
            'id: 20\nevent: snapshot\ndata: ${jsonEncode(status(5))}\n\n',
          );
          await response.flush();
        }
        return;
      }
      if (path.endsWith('/info')) {
        data = {
          'apiVersion': 1,
          'capabilities': [
            'events',
            'hotSettings',
            'hotRoutes',
            'hotProfiles',
            'tunnels',
            'targetRoutes',
            'routingMode',
            'overviewTests',
            'traffic',
            'persistentHistory',
          ],
        };
      }
      if (path.endsWith('/traffic')) data = trafficFixture();
      if (path.endsWith('/status')) data = status(0);
      if (path.endsWith('/config')) {
        configReads++;
        data = {
          'version': 1,
          'local': <String, Object>{},
          'defaultConnectionId': 'one',
          'connections': [
            {
              'id': 'one',
              'name': '测试',
              'hasPassword': true,
              'config': {'server.host': 'localhost'},
            },
          ],
        };
      }
      if (path.endsWith('/logs')) {
        logReads++;
        data = {
          'items': [
            {
              'id': 1,
              'time': '',
              'level': 'INFO',
              'message': '消息含 ERROR 字样但级别是 INFO',
            },
          ],
          'cursor': 1,
          'latestCursor': 1,
          'truncated': false,
        };
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'revision': revision, 'data': data}));
      await request.response.close();
    });
    try {
      await controller.endpointFile.parent.create(recursive: true);
      await controller.endpointFile.writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:${server.port}',
          'apiVersion': 1,
          'token': token,
          'pid': 1,
        }),
      );
      await controller.connect(ProxyProfile(), '', launch: false);
      expect(controller.configurationRevision, 1);
      final events = <int>[];
      controller.addListener(() {
        if (controller.connections.isNotEmpty) {
          events.add(controller.connections.first.activeTunnels);
        }
      });
      expect(await resumed.future.timeout(const Duration(seconds: 5)), '10');
      for (var i = 0; i < 50 && logReads == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events, contains(3));
      expect(events, contains(5));
      expect(controller.tunnels, hasLength(5));
      expect(controller.tunnels.first.target, 'example.test:443');
      expect(controller.configurationRevision, 2);
      expect(controller.configurationChanged, isFalse);
      expect(configReads, greaterThanOrEqualTo(2));
      expect(logReads, 1);
      expect(controller.logs.single.level, 'INFO');
      expect(controller.logs.single.message, contains('ERROR'));
      expect(checks.every((value) => value), isTrue);
    } finally {
      controller.dispose();
      for (final stream in streams) {
        try {
          await stream.close();
        } catch (_) {
          /* 订阅已断开。 */
        }
      }
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
  test('发现文件拒绝向非本机地址发送令牌', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-discovery-',
    );
    final controller = ProxyController(directory: directory);
    try {
      await controller.endpointFile.parent.create(recursive: true);
      await controller.endpointFile.writeAsString(
        jsonEncode({
          'url': 'http://example.com:9090',
          'apiVersion': 1,
          'token': 'x' * 32,
        }),
      );
      await expectLater(controller.attach(), throwsStateError);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });
}
