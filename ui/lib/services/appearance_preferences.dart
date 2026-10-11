import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;

/// 外观偏好独立于内核配置和开发运行路径，所有应用包都读取同一处设置。
class AppearancePreferences {
  Future<ThemeMode> read(Directory directory) async {
    final file = File('${directory.path}/appearance.json');
    if (!await file.exists()) return ThemeMode.system;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final name = data['themeMode'];
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == name,
      orElse: () => throw const FormatException('无效的主题模式'),
    );
  }

  Future<void> write(Directory directory, ThemeMode mode) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/appearance.json.tmp');
    await file.writeAsString(jsonEncode({'themeMode': mode.name}), flush: true);
    await file.rename('${directory.path}/appearance.json');
  }
}
