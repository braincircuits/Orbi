import 'dart:convert';
import 'dart:io';

class RuntimePaths {
  const RuntimePaths(this.javaPath, this.jarPath);
  final String javaPath;
  final String jarPath;
}

/// 只读写当前客户端的启动路径，不保存代理配置或凭据。
class RuntimePreferences {
  Future<RuntimePaths> read(Directory directory) async {
    final file = File('${directory.path}/ui.json');
    if (!await file.exists()) return const RuntimePaths('', '');
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return RuntimePaths(
      data['javaPath'] as String? ?? '',
      data['jarPath'] as String? ?? '',
    );
  }

  Future<void> write(Directory directory, RuntimePaths paths) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/ui.json.tmp');
    await file.writeAsString(
      jsonEncode({'javaPath': paths.javaPath, 'jarPath': paths.jarPath}),
      flush: true,
    );
    await file.rename('${directory.path}/ui.json');
  }
}
