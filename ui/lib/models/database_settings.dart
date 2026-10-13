import 'dart:convert';

/// 内核启动配置独立于代理配置；切换数据库不会复制连接或历史记录。
class DatabaseSettings {
  const DatabaseSettings({
    this.type = 'sqlite',
    this.path = '',
    this.host = '127.0.0.1',
    this.port = '5432',
    this.database = 'network',
    this.username = '',
    this.password = '',
    this.verifyTls = true,
  });
  final String type, path, host, port, database, username, password;
  final bool verifyTls;
  String get label => labels[type]!;
  static const labels = {
    'sqlite': 'SQLite',
    'postgresql': 'PostgreSQL',
    'mysql': 'MySQL',
  };

  void validate() {
    if (!labels.containsKey(type)) throw const FormatException('请选择数据库类型');
    if (type == 'sqlite') {
      if (path.trim().isEmpty) throw const FormatException('请填写 SQLite 文件路径');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(host)) {
      throw const FormatException('数据库地址无效，IPv6 无需方括号');
    }
    final number = int.tryParse(port);
    if (number == null || number < 1 || number > 65535) {
      throw const FormatException('数据库端口需要为 1 至 65535');
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(database)) {
      throw const FormatException('数据库名称只支持字母、数字、下划线和连字符');
    }
    if (username.trim().isEmpty) throw const FormatException('请填写数据库用户名');
  }

  String encode() {
    validate();
    final values = type == 'sqlite'
        ? {'type': type, 'path': path}
        : {
            'type': type,
            'host': host,
            'port': port,
            'database': database,
            'username': username,
            'password': password,
            'sslMode': verifyTls ? 'verify-full' : 'disable',
          };
    return '${values.entries.map((entry) => '${entry.key}=${_escape(entry.value)}').join('\n')}\n';
  }

  /// 界面生成的 properties 每行一项；所有空白和反斜杠显式转义。
  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll(' ', r'\ ')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t')
      .replaceAll('\f', r'\f');
  factory DatabaseSettings.decode(String text) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator < 1) throw const FormatException('数据库启动配置格式无效');
      final key = line.substring(0, separator).trim();
      if (values.containsKey(key)) throw const FormatException('数据库启动配置存在重复字段');
      values[key] = _unescape(line.substring(separator + 1));
    }
    final type = values['type'];
    final allowed = type == 'sqlite'
        ? {'type', 'path'}
        : {
            'type',
            'host',
            'port',
            'database',
            'username',
            'password',
            'sslMode',
          };
    if (values.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('数据库启动配置包含不支持的字段');
    }
    if (type != 'sqlite' &&
        !{'verify-full', 'disable'}.contains(values['sslMode'])) {
      throw const FormatException('数据库 TLS 设置无效');
    }
    final result = DatabaseSettings(
      type: type ?? '',
      path: values['path'] ?? '',
      host: values['host'] ?? '',
      port: values['port'] ?? '',
      database: values['database'] ?? '',
      username: values['username'] ?? '',
      password: values['password'] ?? '',
      verifyTls: values['sslMode'] != 'disable',
    );
    result.validate();
    return result;
  }
  static String _unescape(String value) {
    final output = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (value[i] != r'\') {
        output.write(value[i]);
        continue;
      }
      if (++i == value.length) throw const FormatException('数据库启动配置转义无效');
      if (value[i] == 'u') {
        if (i + 4 >= value.length) throw const FormatException('数据库启动配置转义无效');
        final code = int.tryParse(value.substring(i + 1, i + 5), radix: 16);
        if (code == null) throw const FormatException('数据库启动配置转义无效');
        output.writeCharCode(code);
        i += 4;
      } else {
        output.write(switch (value[i]) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          'f' => '\f',
          final c => c,
        });
      }
    }
    return output.toString();
  }
}
