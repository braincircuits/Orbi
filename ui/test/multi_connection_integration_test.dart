import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';

void main() {
  final root = Platform.environment['UI_TEST_CORE_ROOT'];
  final java = Platform.environment['UI_TEST_JAVA'];
  test(
    '真实 HTTP/3 与 HTTP/2 转发、在线切换及配置应用边界',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'network-multi-test-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.write('multi-protocol-ok');
        await request.response.close();
      });
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final local = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final localPort = local.port;
      await local.close();
      final cert = '$root/ClientG/src/test/resources/tls/localhost.crt';
      final serverConfig = File('${directory.path}/server.properties');
      await serverConfig.writeAsString(
        'bind=127.0.0.1\nport=$port\nprotocols=http2,http3\npassword=integration-only\ntls.cert=$cert\ntls.key=$root/ClientG/src/test/resources/tls/localhost.key\n',
      );
      Process? server;
      final controller = ProxyController(directory: directory);
      StreamSubscription<String>? output;
      StreamSubscription<String>? diagnostics;
      try {
        server = await Process.start(java!, [
          '--enable-native-access=ALL-UNNAMED',
          '-jar',
          '$root/Server/target/Server-1.0-SNAPSHOT.jar',
          serverConfig.path,
        ], workingDirectory: directory.path);
        final ready = Completer<void>();
        output = server.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.contains('HTTP/2 代理服务端已监听') && !ready.isCompleted) {
                ready.complete();
              }
            });
        diagnostics = server.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) {});
        await ready.future.timeout(const Duration(seconds: 15));
        final profile = ProxyProfile(
          values: {'port': '$localPort'},
          javaPath: java,
          jarPath:
              Platform.environment['UI_TEST_JAR'] ??
              '$root/ClientG/target/clientG-1.0-SNAPSHOT.jar',
          defaultConnectionId: 'h3',
          connections: [
            for (final p in ['http3', 'http2'])
              ConnectionProfile(
                id: p == 'http3' ? 'h3' : 'h2',
                name: p,
                config: {
                  'protocol': p,
                  'server.host': '127.0.0.1',
                  'server.port': '$port',
                  'password': 'integration-only',
                  'tls.ca': cert,
                  'tls.serverName': 'localhost',
                },
              ),
          ],
        );
        Future<void> request() async {
          final client = HttpClient()
            ..findProxy = (_) => 'PROXY 127.0.0.1:$localPort';
          try {
            final response = await (await client.getUrl(
              Uri.parse('http://127.0.0.1:${origin.port}/'),
            )).close();
            expect(response.statusCode, 200);
            expect(
              await response.transform(utf8.decoder).join(),
              'multi-protocol-ok',
            );
          } finally {
            client.close(force: true);
          }
        }

        await controller.start(profile, '');
        await request();
        expect(controller.defaultConnectionId, 'h3');
        final tunnel = await Socket.connect('127.0.0.1', localPort);
        final established = Completer<void>();
        final closed = Completer<void>();
        var header = '';
        final incoming = tunnel.listen(
          (bytes) {
            header += utf8.decode(bytes);
            if (header.contains('\r\n\r\n') && !established.isCompleted) {
              established.complete();
            }
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
        try {
          tunnel.write(
            'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\nHost: 127.0.0.1:${origin.port}\r\n\r\n',
          );
          await tunnel.flush();
          await established.future.timeout(const Duration(seconds: 10));
          expect(header, contains('200'));
          for (
            var i = 0;
            i < 100 &&
                !controller.connections.any((c) => (c.activeTunnels) > 0);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            controller.connections.any((c) => (c.activeTunnels) > 0),
            isTrue,
          );
          await controller.selectConnection('h2');
          await closed.future.timeout(const Duration(seconds: 10));
        } finally {
          tunnel.destroy();
          await incoming.cancel();
        }

        expect(controller.running, isTrue);
        expect(controller.defaultConnectionId, 'h2');
        expect(controller.connections.length, 2);
        await request();
        final renamed = ProxyProfile(
          values: profile.values,
          javaPath: java,
          jarPath: profile.jarPath,
          connections: profile.connections.map((c) => c.copy()).toList(),
          defaultConnectionId: 'h2',
        );
        renamed.connections.last.name = '已改名的 HTTP/2';
        await controller.apply(renamed, '');
        expect(controller.connections.last.name, '已改名的 HTTP/2');
        expect(controller.connection, 'connected');
        final changedLocal = ProxyProfile(
          values: renamed.values,
          connections: renamed.connections.map((c) => c.copy()).toList(),
          defaultConnectionId: 'h2',
          rules: '127.0.0.1',
          javaPath: java,
          jarPath: renamed.jarPath,
        );
        await controller.apply(changedLocal, '');
        expect(controller.appliedProfile!.rules, '127.0.0.1');
        expect(controller.running, isTrue);
        await request();
        await controller.selectConnection('h3');
        await request();
        await controller.disconnect();
        await request();
        for (final id in ['h2', 'h3']) {
          await controller.diagnose('127.0.0.1:${origin.port}', profileId: id);
          for (
            var i = 0;
            i < 200 &&
                !controller.operations.values.any(
                  (job) =>
                      job.state == 'succeeded' && job.result.profileId == id,
                );
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            controller.operations.values.any(
              (job) => job.state == 'succeeded' && job.result.profileId == id,
            ),
            isTrue,
          );
          expect(controller.defaultConnectionId, 'h3');
        }

        await controller.stop();
        expect(controller.running, isFalse);
        expect(controller.logs.join('\n'), isNot(contains('integration-only')));
      } finally {
        await controller.shutdown();
        controller.dispose();
        server?.kill();
        if (server != null) {
          await server.exitCode.timeout(const Duration(seconds: 10));
        }
        await output?.cancel();
        await diagnostics?.cancel();
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip: root == null || java == null
        ? '指定 UI_TEST_CORE_ROOT 和 UI_TEST_JAVA 后运行'
        : false,
  );
}
