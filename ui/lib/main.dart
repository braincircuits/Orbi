import 'package:flutter/material.dart';

import 'ui/desktop_theme.dart';
import 'ui/proxy_home.dart';
import 'view_models/proxy_view_model.dart';

void main() => runApp(const NetworkApp());

class NetworkApp extends StatelessWidget {
  const NetworkApp({super.key, this.model});
  final ProxyViewModel? model;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Network · 代理客户端',
    theme: desktopTheme(Brightness.light),
    darkTheme: desktopTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: ProxyHome(model: model),
  );
}
