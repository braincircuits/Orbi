import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';

void main() {
  test('信任证书绝对路径不拼接数据目录，相对路径仍按数据目录解析', () async {
    final directory = await Directory.systemTemp.createTemp('orbi-ca-path-');
    try {
      final base = await Directory('${directory.path}/data').create();
      final certificate = File('${directory.path}/certificates/测试 CA.crt');
      await certificate.parent.create();
      await certificate.writeAsString('测试公钥证书');
      final profile = ProxyProfile(
        values: {'server.host': 'localhost', 'password': 'test-only'},
      );
      final paths = [
        certificate.absolute.path,
        if (Platform.isWindows) certificate.absolute.path.replaceAll('\\', '/'),
        '../certificates/测试 CA.crt',
      ];
      for (final path in paths) {
        profile.selected.values['tls.ca'] = path;
        expect(
          profile.validate(baseDirectory: base.path),
          isNull,
          reason: path,
        );
      }
      profile.selected.values['tls.ca'] = '${certificate.path}.missing';
      expect(profile.validate(baseDirectory: base.path), contains('找不到信任证书'));
      profile.selected.values['tls.ca'] = '';
      expect(profile.validate(baseDirectory: base.path), isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('规范化地址去重，HTTP/2 与 HTTP/3 可共享同一服务端地址端口', () {
    final profile = ProxyProfile(
      values: {'server.host': 'LOCALHOST.', 'password': 'secret'},
    );
    profile.connections.add(
      ConnectionProfile(
        id: 'second',
        name: '第二个',
        config: {'server.host': 'localhost', 'password': 'secret'},
      ),
    );
    expect(profile.validate(), contains('不能重复'));
    profile.connections.last.values['protocol'] = 'http2';
    expect(profile.validate(), isNull);
    profile.defaultConnectionId = 'missing';
    expect(profile.validate(), contains('默认连接'));
  });
}
