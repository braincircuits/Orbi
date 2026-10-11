import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_bridge.dart';
import '../view_models/proxy_view_model.dart';
import 'widgets/desktop_widgets.dart';
import 'desktop_theme.dart';
import 'desktop_icons.dart';
import 'pages/overview_page.dart';
import 'pages/configuration_page.dart';
import 'pages/routes_page.dart';
import 'pages/diagnostics_page.dart';
import 'pages/logs_page.dart';
import 'pages/tunnels_page.dart';
import 'pages/settings_dialog.dart';

class ProxyHome extends StatefulWidget {
  const ProxyHome({super.key, this.model});
  final ProxyViewModel? model;
  @override
  State<ProxyHome> createState() => _ProxyHomeState();
}

class _ProxyHomeState extends State<ProxyHome> {
  late final ProxyViewModel model;
  final keyboardFocus = FocusNode(skipTraversal: true);
  late final AppLifecycleListener lifecycle;
  late final StreamSubscription<UiMessage> messages;
  int previousPage = 0;
  bool settingsOpen = false;
  (int, int)? overviewGeneration;
  bool overviewRefreshing = false;
  final titleDragKey = GlobalKey();
  (Size, int)? titlebarLayout;

  void _configureTitlebar(Size size) {
    final layout = (size, model.page);
    if (titlebarLayout == layout) return;
    titlebarLayout = layout;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = titleDragKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
      unawaited(
        NativeBridge().configureTitlebar(
          right: right,
          top: box.localToGlobal(Offset.zero).dy,
          height: box.size.height,
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    model = widget.model ?? ProxyViewModel();
    model.addListener(_modelChanged);
    messages = model.messages.stream.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message.text),
          backgroundColor: message.failure
              ? Theme.of(context).colorScheme.error
              : null,
        ),
      );
    });
    NativeBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'showSettings') {
        unawaited(_showSettings());
        return;
      }
      await model.handleNativeCall(call);
    });
    lifecycle = AppLifecycleListener(
      onExitRequested: () async => await model.prepareToExit()
          ? AppExitResponse.exit
          : AppExitResponse.cancel,
    );
    unawaited(model.initialize());
    scheduleMicrotask(_refreshOverviewIfReady);
  }

  void _modelChanged() {
    if (!mounted) return;
    if (previousPage != model.page) {
      previousPage = model.page;
      keyboardFocus.requestFocus();
    }
    if (!model.proxy.connected || !model.proxy.running) {
      overviewGeneration = null;
    }
    setState(() {});
    scheduleMicrotask(_refreshOverviewIfReady);
  }

  Future<void> _refreshOverviewIfReady() async {
    if (!mounted ||
        model.page != 0 ||
        overviewRefreshing ||
        model.locked ||
        !model.proxy.connected ||
        !model.proxy.running) {
      return;
    }
    final generation = (
      model.proxy.kernelGeneration,
      model.proxy.networkGeneration,
    );
    if (overviewGeneration == generation) return;
    // 每个实际连接状态只自动检测一次；窗口焦点和页面导航不重新发起网络请求。
    overviewGeneration = generation;
    overviewRefreshing = true;
    try {
      await model.refreshOverview();
    } finally {
      overviewRefreshing = false;
      if (mounted &&
          overviewGeneration !=
              (model.proxy.kernelGeneration, model.proxy.networkGeneration)) {
        scheduleMicrotask(_refreshOverviewIfReady);
      }
    }
  }

  @override
  void dispose() {
    NativeBridge.channel.setMethodCallHandler(null);
    lifecycle.dispose();
    unawaited(messages.cancel());
    model.removeListener(_modelChanged);
    if (widget.model == null) model.dispose();
    keyboardFocus.dispose();
    super.dispose();
  }

  static const pages = [
    (DesktopIcons.dashboard, '概览', '代理概览'),
    (DesktopIcons.connections, '连接配置', '连接配置'),
    (DesktopIcons.routes, '路由规则', '路由规则'),
    (DesktopIcons.logs, '运行日志', '运行日志'),
    (DesktopIcons.tunnels, '活跃隧道', '活跃隧道'),
    (DesktopIcons.diagnostics, '连接诊断', '连接诊断'),
  ];

  static const navigationOrder = [0, 1, 4, 2, 5, 3];

  Future<void> _reload() async {
    if (model.dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新读取内核配置'),
          content: const Text('这会丢弃当前尚未应用的草稿。读取后请核对内容，再提交修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留草稿'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('丢弃并读取'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await model.reload();
  }

  Future<void> _showSettings() async {
    if (settingsOpen) return;
    settingsOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => SettingsDialog(model: model),
      );
    } finally {
      settingsOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = DesktopWidgets(context, model);
    _configureTitlebar(MediaQuery.sizeOf(context));
    return Shortcuts(
      // 表单焦点遍历使用统一规则，避免依赖宿主文本输入事件转换。
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.tab, shift: true):
            PreviousFocusIntent(),
      },
      child: CallbackShortcuts(
        bindings: {
          for (final meta in [true, false]) ...{
            for (var i = 0; i < pages.length; i++)
              SingleActivator(
                [
                  LogicalKeyboardKey.digit1,
                  LogicalKeyboardKey.digit2,
                  LogicalKeyboardKey.digit3,
                  LogicalKeyboardKey.digit4,
                  LogicalKeyboardKey.digit5,
                  LogicalKeyboardKey.digit6,
                ][i],
                meta: meta,
                control: !meta,
              ): () =>
                  model.navigate(navigationOrder[i]),
            SingleActivator(
              LogicalKeyboardKey.comma,
              meta: meta,
              control: !meta,
            ): () =>
                _showSettings(),
            SingleActivator(
              LogicalKeyboardKey.keyS,
              meta: meta,
              control: !meta,
            ): () {
              if (model.canApply) unawaited(model.apply());
            },
            SingleActivator(
              LogicalKeyboardKey.enter,
              meta: meta,
              control: !meta,
            ): () {
              if (model.canApply) unawaited(model.apply());
            },
          },
        },
        child: Focus(
          autofocus: true,
          focusNode: keyboardFocus,
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Scaffold(
              body: Row(
                children: [
                  _sidebar(
                    context,
                    ui,
                    extended: MediaQuery.sizeOf(context).width >= 760,
                  ),
                  VerticalDivider(width: 1, color: ui.line),
                  Expanded(
                    child: Column(
                      children: [
                        _toolbar(context, ui),
                        const Divider(),
                        Expanded(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: DesktopDesign.contentMaxWidth,
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal:
                                      MediaQuery.sizeOf(context).width < 760
                                      ? 18
                                      : 28,
                                  vertical:
                                      MediaQuery.sizeOf(context).height < 700
                                      ? 18
                                      : 26,
                                ),
                                child: AbsorbPointer(
                                  absorbing: model.locked,
                                  child: IndexedStack(
                                    index: model.page,
                                    children: [
                                      OverviewPage(
                                        model: model,
                                        onSettings: _showSettings,
                                      ),
                                      ConfigurationPage(model: model),
                                      RoutesPage(model: model),
                                      LogsPage(model: model),
                                      TunnelsPage(model: model),
                                      DiagnosticsPage(model: model),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        _statusBar(context, ui),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidebar(
    BuildContext context,
    DesktopWidgets ui, {
    required bool extended,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      width: extended ? DesktopDesign.navigationWidth : 150,
      child: NavigationDrawer(
        key: const ValueKey('desktop-navigation'),
        selectedIndex: navigationOrder.indexOf(model.page),
        onDestinationSelected: (index) =>
            model.navigate(navigationOrder[index]),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1.5),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(22, 72, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                key: const ValueKey('desktop-brand'),
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(DesktopIcons.globe, size: 19, color: ui.accent),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Network',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 25),
              Text('工作区', style: TextStyle(fontSize: 10, color: ui.muted)),
            ],
          ),
        ),
        footer: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: _showSettings,
                style: TextButton.styleFrom(foregroundColor: ui.ink),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('设置…'),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 14),
              Row(
                children: [
                  ui.dot(model.proxy.connected),
                  const SizedBox(width: 7),
                  Text(
                    model.proxy.connected ? '本机内核已连接' : '内核未连接',
                    style: theme.textTheme.bodySmall!.copyWith(fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('API v1', style: TextStyle(fontSize: 10, color: ui.muted)),
            ],
          ),
        ),
        children: [
          for (final entry in navigationOrder.indexed)
            NavigationDrawerDestination(
              icon: Tooltip(
                message: '${pages[entry.$2].$2}  Ctrl/⌘+${entry.$1 + 1}',
                child: Icon(pages[entry.$2].$1),
              ),
              label: Text(pages[entry.$2].$2),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context, DesktopWidgets ui) => Container(
    height: DesktopDesign.toolbarHeight,
    color: Theme.of(context).colorScheme.surface,
    padding: const EdgeInsets.only(right: 22),
    key: const ValueKey('desktop-titlebar'),
    child: Row(
      children: [
        Expanded(
          child: _windowDragArea(
            key: titleDragKey,
            child: Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  pages[model.page].$3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ui.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (model.page != 0) ...[
          ui.dot(model.proxy.connected && model.proxy.running, size: 6),
          const SizedBox(width: 7),
          Text(
            model.loading
                ? '准备中…'
                : model.proxy.running
                ? '代理运行中'
                : '代理已停止',
            style: TextStyle(fontSize: 11, color: ui.muted),
          ),
        ],
        if (model.page == 2) ...[
          const SizedBox(width: 12),
          FilledButton(
            onPressed: model.locked ? null : model.apply,
            child: const Text('应用配置'),
          ),
        ],
      ],
    ),
  );

  // 原生宿主仅接管拖动区域的鼠标事件，共享界面保持统一的 Flutter 绘制。
  Widget _windowDragArea({required Key key, required Widget child}) =>
      SizedBox(key: key, height: DesktopDesign.toolbarHeight, child: child);

  Widget _statusBar(BuildContext context, DesktopWidgets ui) => Container(
    height: 36,
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: ui.line.withValues(alpha: .6), width: .5),
      ),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      children: [
        if (model.locked) ...[
          SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: ui.muted),
          ),
          const SizedBox(width: 7),
        ],
        Text(
          model.loading
              ? model.proxy.connected
                    ? '正在准备代理…'
                    : '正在读取内核配置…'
              : model.locked
              ? '正在处理…'
              : !model.proxy.connected
              ? '等待连接内核'
              : model.proxy.configurationChanged
              ? '正在同步内核配置…'
              : model.dirty
              ? '草稿未应用'
              : '所有配置已保存',
          style: TextStyle(color: ui.muted, fontSize: 11),
        ),
        const Spacer(),
        IconButton(
          tooltip: '重新读取内核配置',
          onPressed: model.locked ? null : _reload,
          icon: Icon(Icons.refresh, size: 14, color: ui.muted),
        ),
      ],
    ),
  );
}
