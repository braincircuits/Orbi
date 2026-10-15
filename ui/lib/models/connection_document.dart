import 'proxy_profile.dart';

/// 可交换的连接参数，不携带本机路径设置、默认连接或运行状态。
class ConnectionDocument {
  static List<ConnectionProfile> parse(Map<String, dynamic> document) {
    if (document.length != 3 ||
        document['version'] != 1 ||
        document['kind'] != 'network-connections' ||
        document['connections'] is! List) {
      throw const FormatException('连接文件格式或版本无效');
    }
    final source = document['connections'] as List;
    if (source.isEmpty || source.length > 128) {
      throw const FormatException('连接数量应为 1～128');
    }
    const keys = {
      'protocol',
      'server.host',
      'server.port',
      'username',
      'password',
      'tls.ca',
      'tls.serverName',
      'connectTimeoutMillis',
      'idleTimeoutSeconds',
      'maxStreams',
    };
    return List.unmodifiable(
      source.indexed.map((entry) {
        final value = entry.$2;
        if (value is! Map<String, dynamic> ||
            value.length != 2 ||
            value['name'] is! String ||
            (value['name'] as String).trim().isEmpty ||
            value['config'] is! Map<String, dynamic>) {
          throw FormatException('第 ${entry.$1 + 1} 个连接结构无效');
        }
        final raw = value['config'] as Map<String, dynamic>;
        if (raw.entries.any(
          (e) => !keys.contains(e.key) || e.value is! String,
        )) {
          throw FormatException('第 ${entry.$1 + 1} 个连接包含未知或无效参数');
        }
        final result = ConnectionProfile(
          id: 'import-${entry.$1}',
          name: (value['name'] as String).trim(),
          config: raw.map((k, v) => MapEntry(k, v as String)),
        );
        final port = int.tryParse(result.values['server.port']!);
        if (result.values['server.host']!.trim().isEmpty ||
            !{'http2', 'http3'}.contains(result.protocol) ||
            port == null ||
            port < 1 ||
            port > 65535) {
          throw FormatException('第 ${entry.$1 + 1} 个连接地址、端口或协议无效');
        }
        return result;
      }),
    );
  }

  /// 先构建候选草稿再整体替换，文件自身 ID 不参与覆盖，避免误关联原有密码。
  static List<ConnectionProfile> merge(
    List<ConnectionProfile> current,
    List<ConnectionProfile> incoming,
    List<String?> replacements,
    String prefix,
  ) {
    if (incoming.length != replacements.length) throw StateError('导入选择无效');
    final used = <String>{};
    final result = current.map((c) => c.copy()).toList();
    for (var i = 0; i < incoming.length; i++) {
      final id = replacements[i];
      final previous = id == null
          ? null
          : current.where((c) => c.id == id).firstOrNull;
      if (id != null && (previous == null || !used.add(id))) {
        throw StateError('同一现有连接只能覆盖一次');
      }
      final values = {...incoming[i].values};
      // 不带密码的覆盖沿用该连接自己的已保存密码；新增连接必须补填。
      if (previous != null && values['password']!.isEmpty) {
        values['password'] = previous.values['password']!;
      }
      var name = incoming[i].name;
      if (id == null) {
        var suffix = 1;
        while (result.any((c) => c.name == name)) {
          name = '${incoming[i].name}（导入 ${suffix++}）';
        }
      }
      final next = ConnectionProfile(
        id: id ?? '$prefix-$i',
        name: name,
        config: values,
        hasPassword: previous?.hasPassword ?? false,
      );
      if (id == null) {
        result.add(next);
      } else {
        result[result.indexWhere((c) => c.id == id)] = next;
      }
    }
    if (result.length > 128) throw StateError('合并后连接数量不能超过 128');
    return result;
  }
}
