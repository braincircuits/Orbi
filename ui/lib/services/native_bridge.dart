import 'package:flutter/services.dart';

/// 原生窗口、文件选择和应用目录服务。
class NativeBridge {
  static const channel = MethodChannel('network_ui/desktop');

  Future<Map<String, String>> environment() async {
    final value = await channel.invokeMapMethod<String, String>('environment');
    if (value == null) throw StateError('原生环境信息为空');
    return value;
  }

  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) => channel.invokeMethod('desktopState', {
    'running': running,
    'busy': busy,
    'canApply': canApply,
  });
  Future<void> showWindow() => channel.invokeMethod('showWindow');
  Future<bool> tunServiceInstalled() async =>
      await channel.invokeMethod<bool>('tunServiceInstalled') == true;
  Future<void> removeTunService() => channel.invokeMethod('removeTunService', {
    'helper': const String.fromEnvironment('PROXY_TUN'),
  });
  Future<void> startTun(String endpoint, String ticket) =>
      channel.invokeMethod('startTun', {
        'endpoint': endpoint,
        'ticket': ticket,
        'helper': const String.fromEnvironment('PROXY_TUN'),
      });
  Future<void> configureTitlebar({
    required double right,
    required double top,
    required double height,
    required String brightness,
  }) => channel.invokeMethod('configureTitlebar', {
    'right': right,
    'top': top,
    'height': height,
    'brightness': brightness,
  });

  Future<String?> chooseFile(String kind) =>
      channel.invokeMethod<String>('chooseFile', kind);
  Future<String?> exportLogs(String text) =>
      channel.invokeMethod<String>('exportLogs', text);
}
