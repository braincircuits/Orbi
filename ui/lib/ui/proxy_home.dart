import 'dart:async';
import 'dart:math' as math;
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
  const ProxyHome({super.key, required this.model});
  final ProxyViewModel model;
  @override
  State<ProxyHome> createState() => _ProxyHomeState();
}

class _ProxyHomeState extends State<ProxyHome> {
  late final ProxyViewModel model;
  final keyboardFocus = FocusNode(skipTraversal: true);
  late final AppLifecycleListener lifecycle;
  late final StreamSubscription<UiMessage> messages;
  UiMessage? visibleMessage;
  int previousPage = 0;
  bool settingsOpen = false;
  (int, int)? overviewGeneration;
  bool overviewRefreshing = false;
  final titleDragKey = GlobalKey();
  (Size, int, String, double, Brightness)? titlebarLayout;

  void _configureTitlebar(Size size) {
    final layout = (
      size,
      model.page,
      model.page == 0 ? '' : _proxyState,
      MediaQuery.textScalerOf(context).scale(14),
      Theme.of(context).brightness,
    );
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
          brightness: layout.$5.name,
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    model = widget.model;
    model.addListener(_modelChanged);
    messages = model.messages.stream.listen((message) {
      if (!mounted) return;
      if (visibleMessage?.text == message.text &&
          visibleMessage?.failure == message.failure) {
        return;
      }
      visibleMessage = message;
      final theme = Theme.of(context);
      final size = MediaQuery.sizeOf(context);
      final messenger = ScaffoldMessenger.of(context);
      // 新消息替换当前提示；重复消息不排队，也不延长显示时间。
      messenger.removeCurrentSnackBar();
      final controller = messenger.showSnackBar(
        SnackBar(
          key: const ValueKey('desktop-message'),
          width: math.min(520, size.width - 32),
          duration: Duration(seconds: message.failure ? 8 : 4),
          content: Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  message.failure
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  color: message.failure
                      ? theme.colorScheme.error
                      : DesktopDesign.success(theme.brightness),
                  size: 20,
                  semanticLabel: message.failure ? '操作失败' : '操作完成',
                ),
                const SizedBox(width: DesktopDesign.spacing),
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: size.height * .3),
                    child: SingleChildScrollView(child: Text(message.text)),
                  ),
                ),
              ],
            ),
          ),
        ),
        snackBarAnimationStyle: AnimationStyle.noAnimation,
      );
      unawaited(
        controller.closed.then((_) {
          if (identical(visibleMessage, message)) visibleMessage = null;
        }),
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureTitlebar(MediaQuery.sizeOf(context));
  }

  String get _proxyState => model.loading
      ? '准备中…'
      : !model.proxy.connected
      ? '内核未连接'
      : model.proxy.running
      ? '代理运行中'
      : '代理已停止';

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
    _configureTitlebar(MediaQuery.sizeOf(context));
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
        animationStyle: AnimationStyle.noAnimation,
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
        animationStyle: AnimationStyle.noAnimation,
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
    final pages = <Widget>[
      OverviewPage(
        model: model,
        visible: model.page == 0,
        onSettings: _showSettings,
      ),
      ConfigurationPage(model: model),
      RoutesPage(model: model),
      LogsPage(model: model, visible: model.page == 3),
      TunnelsPage(model: model, visible: model.page == 4),
      DiagnosticsPage(model: model, visible: model.page == 5),
    ];
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
              if (model.canApply) unawaited(model.applyCurrentPage());
            },
            SingleActivator(
              LogicalKeyboardKey.enter,
              meta: meta,
              control: !meta,
            ): () {
              if (model.canApply) unawaited(model.applyCurrentPage());
            },
          },
        },
        child: Focus(
          autofocus: true,
          focusNode: keyboardFocus,
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Scaffold(
              backgroundColor: model.sidebarMaterial
                  ? Colors.transparent
                  : null,
              body: Row(
                children: [
                  _sidebar(
                    context,
                    ui,
                    extended: MediaQuery.sizeOf(context).width >= 760,
                  ),
                  VerticalDivider(width: 1, color: ui.line),
                  Expanded(
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
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
                                    horizontal: DesktopDesign.pageInset(
                                      MediaQuery.sizeOf(context).width,
                                    ),
                                    vertical:
                                        MediaQuery.sizeOf(context).height < 700
                                        ? 18
                                        : 26,
                                  ),
                                  child: AbsorbPointer(
                                    absorbing: model.locked,
                                    child: ExcludeFocus(
                                      excluding: model.locked,
                                      child: IndexedStack(
                                        index: model.page,
                                        children: [
                                          for (final (index, page)
                                              in pages.indexed)
                                            // 保留状态，同时停止隐藏页的进度和光标动画。
                                            TickerMode(
                                              enabled: model.page == index,
                                              child: page,
                                            ),
                                        ],
                                      ),
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
        backgroundColor: model.sidebarMaterial ? Colors.transparent : null,
        tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
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
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      DesktopIcons.globe,
                      size: 19,
                      color: theme.colorScheme.onPrimary,
                    ),
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
              Text(
                '网络',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: ui.muted,
                ),
              ),
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
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('设置…'),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 14),
              Row(
                children: [
                  ui.dot(model.proxy.connected),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      model.proxy.connected ? '本机内核已连接' : '内核未连接',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                model.loading
                    ? '正在准备运行环境'
                    : model.proxy.connected
                    ? _proxyState
                    : '请检查连接状态',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        children: [
          for (final entry in navigationOrder.indexed) ...[
            if (entry.$1 == 4)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 12, 8),
                child: Text(
                  '工具',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ui.muted,
                  ),
                ),
              ),
            // 内置目的地有固定的半秒选中动画；桌面导航与正文在同一帧更新。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              child: Material(
                animationDuration: Duration.zero,
                color: model.page == entry.$2
                    ? theme.navigationDrawerTheme.indicatorColor
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(
                  DesktopDesign.controlRadius,
                ),
                child: ListTile(
                  key: ValueKey('navigation-${entry.$2}'),
                  selected: model.page == entry.$2,
                  selectedColor: theme.colorScheme.onSurface,
                  textColor: theme.colorScheme.onSurface,
                  iconColor: theme.colorScheme.primary,
                  minTileHeight: 34,
                  minVerticalPadding: 0,
                  horizontalTitleGap: 12,
                  minLeadingWidth: 16,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      DesktopDesign.controlRadius,
                    ),
                  ),
                  onTap: () => model.navigate(entry.$2),
                  leading: Tooltip(
                    message: '${pages[entry.$2].$2}  Ctrl/⌘+${entry.$1 + 1}',
                    child: Icon(
                      pages[entry.$2].$1,
                      size: DesktopDesign.navigationIconSize,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  title: Text(
                    pages[entry.$2].$2,
                    style: TextStyle(
                      fontSize: DesktopDesign.bodyFontSize,
                      fontWeight: model.page == entry.$2
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _contentBar(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: DesktopDesign.contentMaxWidth,
      ),
      child: child,
    ),
  );

  Widget _toolbar(BuildContext context, DesktopWidgets ui) => _contentBar(
    Container(
      height: DesktopDesign.toolbarHeight,
      color: Theme.of(context).colorScheme.surface,
      padding: EdgeInsets.only(
        right: DesktopDesign.pageInset(MediaQuery.sizeOf(context).width),
      ),
      key: const ValueKey('desktop-titlebar'),
      child: Row(
        children: [
          Expanded(
            child: _windowDragArea(
              key: titleDragKey,
              child: Padding(
                padding: EdgeInsets.only(
                  left: DesktopDesign.pageInset(
                    MediaQuery.sizeOf(context).width,
                  ),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    pages[model.page].$3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
            ),
          ),
          if (model.page != 0) ...[
            ui.dot(model.proxy.connected && model.proxy.running, size: 6),
            const SizedBox(width: 7),
            Text(_proxyState, style: TextStyle(fontSize: 11, color: ui.muted)),
          ],
        ],
      ),
    ),
  );

  // 原生宿主仅接管拖动区域的鼠标事件，共享界面保持统一的 Flutter 绘制。
  Widget _windowDragArea({required Key key, required Widget child}) =>
      SizedBox(key: key, height: DesktopDesign.toolbarHeight, child: child);

  Widget _statusBar(BuildContext context, DesktopWidgets ui) => _contentBar(
    Container(
      constraints: const BoxConstraints(minHeight: 36),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: ui.line.withValues(alpha: .6), width: .5),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: DesktopDesign.pageInset(MediaQuery.sizeOf(context).width),
      ),
      child: Row(
        children: [
          if (model.showBlockingProgress) ...[
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: ui.muted),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              model.loading
                  ? model.proxy.connected
                        ? '正在准备代理…'
                        : '正在读取内核配置…'
                  : model.showBlockingProgress
                  ? '正在处理…'
                  : !model.proxy.connected
                  ? '等待连接内核'
                  : model.proxy.configurationChanged &&
                        !model.routingModeChanging
                  ? '正在同步内核配置…'
                  : model.dirty
                  ? '草稿未应用'
                  : '所有配置已保存',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          const SizedBox(width: DesktopDesign.spacing),
          IconButton(
            tooltip: '重新读取内核配置',
            onPressed: model.locked ? null : _reload,
            icon: Icon(Icons.refresh, size: 14, color: ui.muted),
          ),
        ],
      ),
    ),
  );
}
