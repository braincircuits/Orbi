import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/database_settings.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';

void main() {
  test(
    '真实内核切换 SQLite 文件、重新打开旧库及失败后手动恢复',
    () async {
      final jar = Platform.environment['NETWORK_TEST_CLIENT_JAR'];
      final java = Platform.environment['NETWORK_TEST_JAVA'];
      if (jar == null || java == null) return;
      final directory = await Directory.systemTemp.createTemp(
        'database-kernel-',
      );
      final kernel = ProxyController(directory: directory);
      final runtime = ProxyProfile(javaPath: java, jarPath: jar);
      try {
        await kernel.connect(runtime, directory.path);
        final original = DatabaseSettings(path: kernel.configPath);
        final initial = ProxyProfile(
          javaPath: java,
          jarPath: jar,
          connections: [],
          defaultConnectionId: '',
          routingMode: 'direct',
        );
        await kernel.apply(initial, directory.path, expectedRevision: 0);
        expect(kernel.revision, 1);
        await kernel.changeDatabase(
          DatabaseSettings(path: '${directory.path}/second.db'),
          runtime,
          directory.path,
        );
        expect(kernel.revision, 0);
        expect(kernel.appliedProfile!.routingMode, 'rules');
        await kernel.changeDatabase(original, runtime, directory.path);
        expect(kernel.revision, 1);
        expect(kernel.appliedProfile!.routingMode, 'direct');
        final remotePath =
            Platform.environment['NETWORK_TEST_UI_POSTGRESQL_CONFIG'];
        if (remotePath != null) {
          final remote = DatabaseSettings.decode(
            await File(remotePath).readAsString(),
          );
          await kernel.changeDatabase(remote, runtime, directory.path);
          expect(kernel.storageBackend, 'postgresql');
          expect(kernel.revision, 0);
          await kernel.apply(initial, directory.path, expectedRevision: 0);
          await kernel.changeDatabase(original, runtime, directory.path);
          expect(kernel.storageBackend, 'sqlite');
          await kernel.changeDatabase(remote, runtime, directory.path);
          expect(kernel.revision, 1);
          expect(kernel.appliedProfile!.routingMode, 'direct');
          await kernel.changeDatabase(original, runtime, directory.path);
        }
        await expectLater(
          kernel.changeDatabase(
            const DatabaseSettings(
              type: 'postgresql',
              host: '127.0.0.1',
              port: '1',
              username: 'test',
              password: 'test',
              verifyTls: false,
            ),
            runtime,
            directory.path,
          ),
          throwsStateError,
        );
        expect((await kernel.databases.read(directory)).type, 'postgresql');
        await kernel.changeDatabase(original, runtime, directory.path);
        expect(kernel.revision, 1);
        await kernel.shutdown();
      } finally {
        if (kernel.canShutdown) await kernel.shutdown();
        kernel.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip:
        Platform.environment['NETWORK_TEST_CLIENT_JAR'] == null ||
        Platform.environment['NETWORK_TEST_JAVA'] == null,
  );
}
