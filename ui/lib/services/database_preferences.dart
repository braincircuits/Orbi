import 'dart:io';

import '../models/database_settings.dart';

/// 单份启动配置原子替换；先收紧临时目录权限，再写入凭据。
class DatabasePreferences {
  File file(Directory directory) =>
      File('${directory.path}/database.properties');
  Future<DatabaseSettings> read(Directory directory) async {
    final source = file(directory);
    if (!await source.exists()) {
      return DatabaseSettings(path: '${directory.path}/kernel.db');
    }
    return DatabaseSettings.decode(await source.readAsString());
  }

  Future<void> write(Directory directory, DatabaseSettings settings) async {
    if (Platform.isWindows && settings.type == 'sqlite') {
      await directory.create(recursive: true);
      final root = directory.absolute.uri.normalizePath().toFilePath();
      final file = File(settings.path);
      final resolved =
          (file.isAbsolute
                  ? file.uri
                  : directory.absolute.uri.resolveUri(file.uri))
              .normalizePath()
              .toFilePath();
      final prefix = root.endsWith(Platform.pathSeparator)
          ? root
          : '$root${Platform.pathSeparator}';
      if (!resolved.toLowerCase().startsWith(prefix.toLowerCase())) {
        throw StateError('Windows 便携版的 SQLite 数据库必须位于程序同级的 data 目录内');
      }
      settings = DatabaseSettings(
        path: resolved.substring(prefix.length).replaceAll('\\', '/'),
      );
    }
    final text = settings.encode();
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.database-');
    try {
      if (Platform.isWindows) {
        final user = Platform.environment['USERNAME'];
        final domain = Platform.environment['USERDOMAIN'];
        if (user == null || user.isEmpty) throw StateError('无法确定当前用户，未保存数据库凭据');
        final identity = domain == null || domain.isEmpty
            ? user
            : '$domain\\$user';
        final result = await Process.run('icacls', [
          staging.path,
          '/inheritance:r',
          '/grant:r',
          '$identity:(OI)(CI)F',
        ]);
        if (result.exitCode != 0) throw StateError('无法保护数据库配置目录，未保存凭据');
      } else {
        final result = await Process.run('chmod', ['700', staging.path]);
        if (result.exitCode != 0) throw StateError('无法保护数据库配置目录，未保存凭据');
      }
      final pending = File('${staging.path}/database.properties');
      await pending.writeAsString(text, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['600', pending.path]);
        if (result.exitCode != 0) throw StateError('无法保护数据库配置文件，未保存凭据');
      }
      await pending.rename(file(directory).path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
