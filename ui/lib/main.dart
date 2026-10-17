import 'package:flutter/material.dart';

import 'ui/desktop_theme.dart';
import 'ui/proxy_home.dart';
import 'view_models/proxy_view_model.dart';

void main() => runApp(const NetworkApp());

class NetworkApp extends StatefulWidget {
  const NetworkApp({super.key, this.model});
  final ProxyViewModel? model;

  @override
  State<NetworkApp> createState() => _NetworkAppState();
}

class _NetworkAppState extends State<NetworkApp> {
  late ProxyViewModel model;

  @override
  void initState() {
    super.initState();
    model = widget.model ?? ProxyViewModel();
  }

  @override
  void didUpdateWidget(NetworkApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.model != oldWidget.model) {
      if (oldWidget.model == null) model.dispose();
      model = widget.model ?? ProxyViewModel();
    }
  }

  @override
  void dispose() {
    if (widget.model == null) model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: model.themeMode,
    // 主题切换保留主页面、导航和表单状态，不随内核状态重建整个应用。
    child: ProxyHome(key: ObjectKey(model), model: model),
    builder: (context, mode, home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Network · 代理客户端',
      theme: desktopTheme(Brightness.light),
      darkTheme: desktopTheme(Brightness.dark),
      themeMode: mode,
      themeAnimationDuration: Duration.zero,
      scrollBehavior: DesktopDesign.scrollBehavior,
      home: home,
    ),
  );
}
