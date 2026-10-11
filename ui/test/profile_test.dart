import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/proxy_profile.dart';

void main() {
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
