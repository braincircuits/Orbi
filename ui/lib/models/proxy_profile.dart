import 'dart:io';

class ConnectionProfile {
  ConnectionProfile({
    required this.id,
    required this.name,
    Map<String, String>? config,
    this.hasPassword = false,
  }) : values = {...ProxyProfile.defaults, ...?config};
  final String id;
  bool hasPassword;
  String name;
  final Map<String, String> values;
  String get protocol => values['protocol']!;
  String get endpoint {
    final host = values['server.host']!;
    return '${host.contains(':') && !host.startsWith('[') ? '[$host]' : host}:${values['server.port']}';
  }

  Map<String, Object> json() => {
    'id': id,
    'name': name,
    'config': Map.fromEntries(
      values.entries.where(
        (e) => !ProxyProfile.localKeys.contains(e.key) && e.value.isNotEmpty,
      ),
    ),
  };
  ConnectionProfile copy() => ConnectionProfile(
    id: id,
    name: name,
    config: values,
    hasPassword: hasPassword,
  );
}

class ProxyProfile {
  ProxyProfile({
    Map<String, String>? values,
    this.rules = '',
    this.routesOverrides = '',
    this.routingMode = 'rules',
    this.javaPath = '',
    this.jarPath = '',
    List<ConnectionProfile>? connections,
    this.defaultConnectionId = 'default',
  }) : values = {...defaults, ...?values} {
    this.connections =
        connections ??
        [ConnectionProfile(id: 'default', name: '默认连接', config: this.values)];
  }
  static const localKeys = {'bind', 'port', 'local.connectTimeoutMillis'};
  static const defaults = <String, String>{
    'protocol': 'http3',
    'server.host': '',
    'server.port': '4433',
    'username': '',
    'password': '',
    'tls.serverName': '',
    'tls.ca': '',
    'bind': '127.0.0.1',
    'port': '8080',
    'connectTimeoutMillis': '10000',
    'local.connectTimeoutMillis': '10000',
    'idleTimeoutSeconds': '300',
    'maxStreams': '1024',
  };
  final Map<String, String> values;
  late List<ConnectionProfile> connections;
  String defaultConnectionId;
  String rules;
  String routesOverrides;
  String routingMode;
  Map<String, String> get targetRoutes {
    final result = <String, String>{};
    for (final line in routesOverrides.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length == 2) result[fields[1]] = fields[0];
    }
    return result;
  }

  String javaPath;
  String jarPath;
  ConnectionProfile get selected =>
      connections.firstWhere((c) => c.id == defaultConnectionId);
  Map<String, Object> get localConfiguration => {
    'routingMode': routingMode,
    'bind': values['bind']!,
    'port': values['port']!,
    'routesInline': rules,
    if (routesOverrides.isNotEmpty) 'routesOverrides': routesOverrides,
    'connectTimeoutMillis': values['local.connectTimeoutMillis']!,
  };
  Map<String, Object> get runtimeConfiguration => {
    'version': 1,
    'local': localConfiguration,
    'defaultConnectionId': defaultConnectionId,
    'connections': connections.map((c) => c.json()).toList(),
  };
  factory ProxyProfile.fromKernel(
    Map<String, dynamic> config, {
    String javaPath = '',
    String jarPath = '',
  }) {
    final local = config['local'] as Map<String, dynamic>? ?? {};
    return ProxyProfile(
      values: {
        'bind': '${local['bind'] ?? '127.0.0.1'}',
        'port': '${local['port'] ?? 8080}',
        'local.connectTimeoutMillis':
            '${local['connectTimeoutMillis'] ?? 10000}',
      },
      connections: (config['connections'] as List)
          .map(
            (item) => ConnectionProfile(
              id: item['id'] as String,
              name: item['name'] as String,
              hasPassword: item['hasPassword'] == true,
              config: (item['config'] as Map<String, dynamic>).map(
                (k, v) => MapEntry(k, '$v'),
              ),
            ),
          )
          .toList(),
      defaultConnectionId: config['defaultConnectionId'] as String,
      routingMode: '${local['routingMode'] ?? 'rules'}',
      rules: '${local['routesInline'] ?? ''}',
      routesOverrides: '${local['routesOverrides'] ?? ''}',
      javaPath: javaPath,
      jarPath: jarPath,
    );
  }
  String? validate({String? baseDirectory}) {
    if (!{'rules', 'direct', 'proxy'}.contains(routingMode)) {
      return '请选择有效的路由模式';
    }
    if (connections.length > 128) return '连接数量不能超过 128';
    if (connections.isEmpty
        ? defaultConnectionId.isNotEmpty
        : !connections.any((c) => c.id == defaultConnectionId)) {
      return '请选择默认连接';
    }
    if (values['bind']!.trim().isEmpty) return '请填写本地监听地址';
    for (final item in {
      'port': (0, 65535),
      'local.connectTimeoutMillis': (100, 120000),
    }.entries) {
      final n = int.tryParse(values[item.key]!);
      if (n == null || n < item.value.$1 || n > item.value.$2) {
        return '${labels[item.key]}应为 ${item.value.$1}～${item.value.$2} 的整数';
      }
    }
    final ids = <String>{};
    final endpoints = <String>{};
    for (final c in connections) {
      if (!ids.add(c.id) || !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(c.id)) {
        return '连接 ID 无效或重复';
      }
      if (c.name.trim().isEmpty) return '请填写连接名称';
      final v = c.values;
      if (!{'http2', 'http3'}.contains(c.protocol)) {
        return '${c.name}：请选择 HTTP/2 或 HTTP/3';
      }
      if (v['server.host']!.trim().isEmpty) return '${c.name}：请填写服务端地址';
      if (RegExp(r'[\s/%]').hasMatch(v['server.host']!)) {
        return '${c.name}：服务端地址只填写域名或 IP，不包含协议、路径或作用域';
      }
      if (v['password']!.trim().isEmpty && !c.hasPassword) {
        return '${c.name}：请填写代理密码';
      }
      for (final item in {
        'server.port': (1, 65535),
        'connectTimeoutMillis': (100, 120000),
        'idleTimeoutSeconds': (10, 86400),
        'maxStreams': (1, 10000),
      }.entries) {
        final n = int.tryParse(v[item.key]!);
        if (n == null || n < item.value.$1 || n > item.value.$2) {
          return '${c.name}：${labels[item.key]}应为 ${item.value.$1}～${item.value.$2} 的整数';
        }
      }
      var host = v['server.host']!.toLowerCase().replaceAll(
        RegExp(r'^\[|\]$'),
        '',
      );
      host =
          InternetAddress.tryParse(host)?.address ??
          host.replaceFirst(RegExp(r'\.$'), '');
      if (!endpoints.add(
        '${c.protocol}|$host|${int.parse(v['server.port']!)}',
      )) {
        return '协议、服务端地址和端口不能重复';
      }
      final ca = v['tls.ca']!;
      final caFile = File(
        ca.startsWith('/') || baseDirectory == null ? ca : '$baseDirectory/$ca',
      );
      if (ca.isNotEmpty && !caFile.existsSync()) {
        return '${c.name}：找不到信任证书，请重新选择';
      }
    }
    return null;
  }

  static const labels = {
    'server.host': '服务端地址',
    'server.port': '服务端端口',
    'username': '用户名',
    'password': '密码',
    'tls.serverName': 'TLS 验证名称',
    'tls.ca': '信任证书',
    'bind': '本地监听地址',
    'port': '本地端口',
    'local.connectTimeoutMillis': '本地请求超时（毫秒）',
    'connectTimeoutMillis': '连接超时（毫秒）',
    'idleTimeoutSeconds': '空闲超时（秒）',
    'maxStreams': '最大并发流数',
  };
}
