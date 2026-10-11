import 'package:flutter/widgets.dart';

/// 与交互原型一致的 Lucide 线条图标，使用本地字体并继承导航主题。
abstract final class DesktopIcons {
  static const dashboard = IconData(0xe1c1, fontFamily: 'Lucide');
  static const connections = IconData(0xe29a, fontFamily: 'Lucide');
  static const routes = IconData(0xe53e, fontFamily: 'Lucide');
  static const logs = IconData(0xe0cc, fontFamily: 'Lucide');
  static const tunnels = IconData(0xe046, fontFamily: 'Lucide');
  static const diagnostics = IconData(0xe038, fontFamily: 'Lucide');
  static const globe = IconData(0xe0e8, fontFamily: 'Lucide');
}
