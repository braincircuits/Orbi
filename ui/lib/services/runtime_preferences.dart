import 'dart:convert';
import 'dart:io';

import '../models/tun_engine.dart';

class RuntimePaths {
  const RuntimePaths(
    this.javaPath,
    this.jarPath, {
    this.tunEngine = TunEngine.outline,
  });
  final String javaPath;
  final String jarPath;
  final TunEngine tunEngine;
}

/// 保存当前客户端的启动路径和 TUN 组件选择，不保存代理配置或凭据。
class RuntimePreferences {
  Future<RuntimePaths> read(Directory directory) async {
    final file = File('${directory.path}/ui.json');
    if (!await file.exists()) return const RuntimePaths('', '');
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return RuntimePaths(
      data['javaPath'] as String? ?? '',
      data['jarPath'] as String? ?? '',
      tunEngine: TunEngine.parse(data['tunEngine'] as String? ?? 'outline'),
    );
  }

  Future<void> write(Directory directory, RuntimePaths paths) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/ui.json.tmp');
    await file.writeAsString(
      jsonEncode({
        'javaPath': paths.javaPath,
        'jarPath': paths.jarPath,
        'tunEngine': paths.tunEngine.name,
      }),
      flush: true,
    );
    await file.rename('${directory.path}/ui.json');
  }
}
