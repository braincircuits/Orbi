import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

// 原生宿主回归测试独立入口，不读取用户配置或启动代理内核。
class _SidebarModel extends ProxyViewModel {
  @override
  Future<void> initialize() async {
    sidebarMaterial = true;
    themeMode.value = ThemeMode.light;
    accept(ProxyProfile());
    loading = false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final model = _SidebarModel();
  var down = 0;
  var up = 0;
  const MethodChannel('network_ui/sidebar_test').setMethodCallHandler((
    call,
  ) async {
    if (call.method == 'dark') {
      model.themeMode.value = ThemeMode.dark;
      return null;
    }
    if (call.method != 'snapshot') throw MissingPluginException();
    final positions = <String, List<double>>{};
    void visit(Element element) {
      final widget = element.widget;
      final label = widget is Text
          ? widget.data
          : widget is Tooltip
          ? widget.message
          : null;
      if (['连接配置', '添加连接', '路由规则', '设置…', '外观', '关闭设置（保留草稿）'].contains(label)) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final point = box.localToGlobal(box.size.center(Offset.zero));
          positions.putIfAbsent(label!, () => [point.dx, point.dy]);
        }
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return {
      'page': model.page,
      'down': down,
      'up': up,
      'connections': model.connectionDrafts.length,
      'positions': positions,
    };
  });
  runApp(
    Listener(
      onPointerDown: (_) => down++,
      onPointerUp: (_) => up++,
      child: NetworkApp(model: model),
    ),
  );
}
