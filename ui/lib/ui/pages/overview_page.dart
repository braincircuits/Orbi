import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/kernel_status.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/traffic_chart.dart';
import 'traffic_history_dialog.dart';

/// 概览只读展示当前配置；检测统一由内核按实际出口执行。
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.model, this.onSettings});
  final ProxyViewModel model;
  final VoidCallback? onSettings;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  ProxyViewModel get model => widget.model;
  DiagnosticOperation? previousExit;
  (int, int)? exitGeneration;

  @override
  void initState() {
    super.initState();
    _rememberExit();
    model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_modelChanged);
      previousExit = null;
      exitGeneration = null;
      model.addListener(_modelChanged);
      _rememberExit();
    }
  }

  void _rememberExit() {
    final proxy = model.proxy;
    final generation = (proxy.kernelGeneration, proxy.networkGeneration);
    if (exitGeneration != generation || !proxy.connected || !proxy.running) {
      previousExit = null;
    }
    exitGeneration = generation;
    final operation = proxy.overviewOperation('exit-ip');
    // 同一网络上下文刷新时继续展示上次结果，避免内容清空造成布局跳动。
    if (!proxy.overviewBusy('exit-ip')) {
      previousExit = operation?.state == 'succeeded' ? operation : null;
    }
  }

  void _modelChanged() {
    setState(_rememberExit);
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = DesktopWidgets(context, model);
    final theme = Theme.of(context);
    final proxy = model.proxy;
    final running = proxy.connected && proxy.running;
    final direct = proxy.routingMode == 'direct';
    final preparing = model.loading && !running;
    final connection = model.activeConnection;
    final applied = proxy.appliedProfile;
    final bind = applied?.values['bind'] ?? '127.0.0.1';
    final port = applied?.values['port'] ?? '8080';
    final localAddress = running
        ? proxy.address
        : '${bind.contains(':') && !bind.startsWith('[') ? '[$bind]' : bind}:$port';
    final latency = proxy.overviewOperation('latency');
    final ip = proxy.overviewOperation('exit-ip');
    final displayedIp = proxy.overviewBusy('exit-ip') ? previousExit : ip;
    final websites = proxy.overviewOperation('websites');
    final canTest = running && !model.locked;
    final modeLabel = switch (proxy.routingMode) {
      'direct' => '直连',
      'proxy' => '全局',
      _ => '规则',
    };
    final serverState = !proxy.connected
        ? '状态未知'
        : !running
        ? '未连接'
        : direct
        ? '未使用'
        : switch (proxy.connection) {
            'connecting' => '正在连接',
            'connected' => '已连接',
            'failed' => '连接失败',
            _ => '等待请求',
          };
    Widget small(String text) => Text(text, style: theme.textTheme.bodySmall);
    Widget title(String text) => Text(text, style: theme.textTheme.titleMedium);
    final actionColor = running
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final toggle = FilledButton(
      key: const ValueKey('overview-toggle'),
      style: FilledButton.styleFrom(
        fixedSize: const Size(
          DesktopDesign.overviewToggleWidth,
          DesktopDesign.overviewControlHeight,
        ),
        padding: EdgeInsets.zero,
        backgroundColor: actionColor,
        foregroundColor: running
            ? theme.colorScheme.onError
            : theme.colorScheme.onPrimary,
      ),
      onPressed: model.locked
          ? null
          : running
          ? model.stop
          : model.start,
      child: Text(
        preparing
            ? '准备中…'
            : running
            ? '停止'
            : '开启',
      ),
    );
    return ui.list('overview', [
      Container(
        key: const ValueKey('overview-service-panel'),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ui.panel,
          borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
          border: Border.all(color: ui.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pair(
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: ui.accent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.power_settings_new_rounded,
                      color: theme.colorScheme.onPrimary,
                      size: 25,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preparing
                              ? proxy.connected
                                    ? '正在启动代理'
                                    : '正在连接代理内核'
                              : running
                              ? '服务运行中'
                              : proxy.connected
                              ? '服务已停止'
                              : '内核未连接',
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            ui.dot(running),
                            const SizedBox(width: 6),
                            Flexible(
                              child: small(
                                '${running ? '正在使用' : '开启后使用'}$modeLabel模式',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              toggle,
              breakpoint: 430,
              stackedAlignment: Alignment.centerRight,
            ),
            const SizedBox(height: 20),
            _pair(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  small('本地 HTTP 代理 · ${running ? '监听中' : '未监听'}'),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: SelectableText(
                          localAddress,
                          style: DesktopDesign.monoText,
                        ),
                      ),
                      _copyButton(localAddress, '复制本地代理地址'),
                    ],
                  ),
                ],
              ),
              Tooltip(
                message: '路由模式：仅作用于接入本地代理的流量；直连／全局模式覆盖路由规则',
                child: SizedBox(
                  width: DesktopDesign.overviewModeWidth * 3,
                  height: DesktopDesign.overviewControlHeight,
                  child: SegmentedButton<String>(
                    key: const ValueKey('overview-mode'),
                    expandedInsets: EdgeInsets.zero,
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(EdgeInsets.zero),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.standard,
                    ),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'rules', label: Text('规则')),
                      ButtonSegment(value: 'direct', label: Text('直连')),
                      ButtonSegment(value: 'proxy', label: Text('全局')),
                    ],
                    selected: {proxy.routingMode},
                    onSelectionChanged: model.locked || !proxy.connected
                        ? null
                        : (selected) => model.setRoutingMode(selected.single),
                  ),
                ),
              ),
              breakpoint: 480,
              stackedAlignment: Alignment.centerRight,
            ),
          ],
        ),
      ),
      if (model.loading) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(
          key: ValueKey('startup-progress'),
          minHeight: 2,
        ),
      ],
      if (proxy.error.isNotEmpty ||
          running && !direct && proxy.connection == 'failed') ...[
        const SizedBox(height: 12),
        ui.notice(
          proxy.error.isNotEmpty ? proxy.error : '服务端连接失败，请检查连接配置或运行连接诊断。',
          Icons.warning_amber_rounded,
          warning: true,
        ),
      ],
      const SizedBox(height: 14),
      Padding(
        padding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final traffic = proxy.connected ? proxy.traffic?.current : null;
            Widget speed(String name, bool sending) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      sending ? Icons.north_east : Icons.south_west,
                      size: 16,
                      color: sending
                          ? DesktopDesign.trafficSend(theme.brightness)
                          : DesktopDesign.trafficReceive(theme.brightness),
                    ),
                    const SizedBox(width: 6),
                    small(name),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  traffic == null
                      ? '—'
                      : '${formatTrafficBytes(running ? (sending ? traffic.sendBytesPerSecond : traffic.receiveBytesPerSecond) : 0)}/s',
                  key: ValueKey(
                    sending ? 'overview-send-rate' : 'overview-receive-rate',
                  ),
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                small(
                  '累计 ${traffic == null ? '—' : formatTrafficBytes(sending ? traffic.sentBytes : traffic.receivedBytes)}',
                ),
              ],
            );
            final items = [
              speed('发送速率', true),
              speed('接收速率', false),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  small('活跃隧道'),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => model.navigate(4),
                    child: Text(
                      proxy.connected ? '${proxy.activeTunnelCount}' : '—',
                      key: const ValueKey('overview-active-tunnels'),
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => model.navigate(4),
                    child: Text(
                      '等待 ${proxy.connected ? proxy.pendingTunnelCount : '—'} · 查看',
                      key: const ValueKey('overview-pending-tunnels'),
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: 'HTTP/2 使用 PING 往返时延；HTTP/3 使用当前 QUIC 路径 RTT。',
                    child: small('连接延迟'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    latency?.state == 'succeeded'
                        ? '${_millis(latency!.result.latencyMillis)} ms'
                        : '—',
                    style: theme.textTheme.headlineMedium,
                  ),
                  TextButton(
                    onPressed:
                        canTest && !direct && !proxy.overviewBusy('latency')
                        ? () => model.startOverview('latency')
                        : null,
                    child: Text(
                      proxy.overviewBusy('latency') ? '检测中…' : '检测延迟',
                    ),
                  ),
                ],
              ),
            ];
            final columns = constraints.maxWidth < 680 ? 2 : 4;
            return Wrap(
              spacing: 16,
              runSpacing: 18,
              children: [
                for (final item in items)
                  SizedBox(
                    width:
                        (constraints.maxWidth - 16 * (columns - 1)) / columns,
                    child: ui.card(
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight:
                              96 *
                              MediaQuery.textScalerOf(context).scale(13) /
                              13,
                        ),
                        child: item,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      const SizedBox(height: 14),
      if (proxy.historyStorageWarning.isNotEmpty)
        ui.notice(
          proxy.historyStorageWarning,
          Icons.warning_amber_outlined,
          warning: true,
        ),
      ui.card(
        Column(
          children: [
            TrafficChart(
              traffic: proxy.traffic,
              connected: proxy.connected,
              running: running,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: proxy.connected
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => TrafficHistoryDialog(proxy: proxy),
                      )
                    : null,
                icon: const Icon(Icons.history, size: 16),
                label: const Text('历史流量'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: DesktopDesign.sectionSpacing),
      LayoutBuilder(
        builder: (context, constraints) {
          final sideBySide = constraints.maxWidth >= 760;
          final cardWidth = sideBySide
              ? (constraints.maxWidth - 16) / 2
              : constraints.maxWidth;
          final stackFields =
              cardWidth < 360 * MediaQuery.textScalerOf(context).scale(13) / 13;
          final result = displayedIp?.state == 'succeeded'
              ? displayedIp!.result
              : null;
          final location = {
            result?.country ?? '',
            result?.region ?? '',
            result?.city ?? '',
          }.where((value) => value.isNotEmpty).join(' · ');
          Widget fields(Widget first, Widget second) => stackFields
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [first, const SizedBox(height: 16), second],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: first),
                    const SizedBox(width: 16),
                    Expanded(child: second),
                  ],
                );
          final connectionBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: DesktopDesign.controlHeight,
                ),
                child: Row(
                  children: [
                    Expanded(child: title(connection?.name ?? '尚未配置连接')),
                    const SizedBox(width: 12),
                    Tooltip(
                      message: '服务端连接',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ui.dot(
                            running &&
                                !direct &&
                                proxy.connection == 'connected',
                          ),
                          const SizedBox(width: 6),
                          Text(serverState),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _value(
                context,
                '当前地址',
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        connection?.endpoint ?? '—',
                        key: const PageStorageKey('overview-endpoint'),
                        style: DesktopDesign.monoText,
                      ),
                    ),
                    if (connection != null)
                      _copyButton(connection.endpoint, '复制服务端地址'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              fields(
                _value(
                  context,
                  '传输协议',
                  Text(
                    connection == null
                        ? '—'
                        : connection.protocol == 'http2'
                        ? 'HTTP/2 · TCP + TLS'
                        : 'HTTP/3 · QUIC',
                  ),
                ),
                _value(
                  context,
                  '最近延迟检测',
                  small(
                    direct
                        ? '直连模式未使用'
                        : !running
                        ? '开启后可检测'
                        : _taskLabel(latency),
                  ),
                ),
              ),
            ],
          );
          final connectionFooter = TextButton.icon(
            onPressed: () => model.navigate(1),
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('管理连接'),
          );
          final exitBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: title(
                      '出口 IP · ${proxy.routingMode == 'rules' ? '按规则查询' : '$modeLabel出口'}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width:
                        112 * MediaQuery.textScalerOf(context).scale(13) / 13,
                    child: TextButton.icon(
                      onPressed: canTest && !proxy.overviewBusy('exit-ip')
                          ? () => model.startOverview('exit-ip')
                          : null,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(
                        proxy.overviewBusy('exit-ip') ? '获取中…' : '刷新',
                        maxLines: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _value(
                context,
                '公网 IP',
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: DesktopDesign.controlHeight,
                  ),
                  child: Row(
                    children: [
                      Flexible(
                        child: SelectableText(
                          result?.ip ?? '—',
                          style: DesktopDesign.monoText,
                        ),
                      ),
                      if (result?.ip != null)
                        _copyButton(result!.ip!, '复制出口 IP'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              fields(
                _value(
                  context,
                  '归属地',
                  Text(
                    location.isEmpty
                        ? result == null
                              ? '—'
                              : '未知'
                        : location,
                  ),
                ),
                _value(
                  context,
                  '运营商 / 网络',
                  Text(
                    result == null
                        ? '—'
                        : result.provider.isEmpty
                        ? '未知'
                        : result.provider,
                  ),
                ),
              ),
            ],
          );
          final exitFooter = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              small(!running ? '开启服务后可获取' : _taskLabel(displayedIp)),
              const SizedBox(height: 4),
              small(
                '来源：ipwho.is · 连接变化后更新，可手动刷新 · 归属地仅供参考${proxy.routingMode == 'rules' ? '；不同目标的出口可能不同' : ''}',
              ),
              if (ip?.state == 'failed') ...[
                const SizedBox(height: 8),
                ui.notice(
                  ip!.result.message ?? '出口 IP 查询失败，请重试',
                  Icons.info_outline,
                  warning: true,
                ),
              ],
            ],
          );
          final connectionHeading = direct ? '代理连接 · 当前未使用' : '当前连接';
          Widget footer(Widget child, String key) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Divider(key: ValueKey(key), height: 24),
              child,
            ],
          );
          if (!sideBySide) {
            Widget details(
              String heading,
              String key,
              Widget body,
              Widget actions,
            ) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ui.heading(heading),
                KeyedSubtree(
                  key: ValueKey(key),
                  child: ui.card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [body, footer(actions, '$key-divider')],
                    ),
                  ),
                ),
              ],
            );
            return Column(
              children: [
                details(
                  connectionHeading,
                  'overview-connection-card',
                  connectionBody,
                  connectionFooter,
                ),
                const SizedBox(height: 18),
                details('出口信息', 'overview-exit-card', exitBody, exitFooter),
              ],
            );
          }
          // 正文和页脚分别共用表格行高，缩放、换行时分隔线仍处于同一基线。
          Widget cell(Widget child, {bool bottom = false}) => Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              bottom ? 0 : 16,
              16,
              bottom ? 16 : 0,
            ),
            child: child,
          );
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: ui.heading(connectionHeading)),
                  const SizedBox(width: 16),
                  Expanded(child: ui.heading('出口信息')),
                ],
              ),
              Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Card(
                            key: const ValueKey('overview-connection-card'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Card(
                            key: const ValueKey('overview-exit-card'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Table(
                    columnWidths: const {1: FixedColumnWidth(16)},
                    defaultVerticalAlignment: TableCellVerticalAlignment.top,
                    children: [
                      TableRow(
                        children: [
                          cell(connectionBody),
                          const SizedBox.shrink(),
                          cell(exitBody),
                        ],
                      ),
                      TableRow(
                        children: [
                          cell(
                            footer(
                              connectionFooter,
                              'overview-connection-card-divider',
                            ),
                            bottom: true,
                          ),
                          const SizedBox.shrink(),
                          cell(
                            footer(exitFooter, 'overview-exit-card-divider'),
                            bottom: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 18),
      ui.card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pair(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title(
                    '网络测试 · ${proxy.routingMode == 'rules' ? '按规则' : '经$modeLabel'}',
                  ),
                  const SizedBox(height: 4),
                  small('遵循当前模式测试网站访问延迟'),
                ],
              ),
              OutlinedButton.icon(
                onPressed: !canTest
                    ? null
                    : proxy.overviewBusy('websites')
                    ? websites == null
                          ? null
                          : () => model.cancelDiagnostic(websites.id)
                    : () => model.startOverview('websites'),
                icon: Icon(
                  proxy.overviewBusy('websites')
                      ? Icons.close
                      : Icons.play_arrow_outlined,
                  size: 16,
                ),
                label: Text(
                  proxy.overviewBusy('websites')
                      ? '取消测试'
                      : websites == null
                      ? '开始测试'
                      : '重新测试',
                ),
              ),
              breakpoint: 400,
            ),
            const SizedBox(height: 16),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: TableBorder(horizontalInside: BorderSide(color: ui.line)),
              children: [
                TableRow(
                  children: [
                    for (final label in ['网站', '延迟', '状态'])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: small(label),
                      ),
                  ],
                ),
                for (final site in const [
                  ('github', 'GitHub', 'github.com'),
                  ('google', 'Google', 'www.google.com'),
                  ('youtube', 'YouTube', 'www.youtube.com'),
                ])
                  _websiteRow(context, site, websites),
              ],
            ),
            const SizedBox(height: 12),
            small('HTTPS 响应头耗时 · 每站最多 5 秒 · 不跟随重定向'),
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              child: small(!running ? '开启服务后可测试' : _taskLabel(websites)),
            ),
            if (websites?.state == 'failed') ...[
              const SizedBox(height: 8),
              ui.notice(
                websites!.result.message ?? '网络测试失败，请重试',
                Icons.info_outline,
                warning: true,
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
    ]);
  }

  TableRow _websiteRow(
    BuildContext context,
    (String, String, String) site,
    DiagnosticOperation? operation,
  ) {
    final result = operation?.result.websites
        .where((item) => item.id == site.$1)
        .firstOrNull;
    final label =
        result?.label ??
        (operation == null
            ? '未测试'
            : operation.state == 'cancelled'
            ? '已取消'
            : operation.state == 'failed'
            ? '未完成'
            : operation.stage == site.$1 && !operation.finished
            ? '检测中'
            : '等待测试');
    final ui = DesktopWidgets(context, model);
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: child,
    );
    return TableRow(
      children: [
        cell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(site.$2),
              Text(site.$3, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        cell(
          Text(
            result?.latencyMillis == null
                ? '—'
                : '${_millis(result!.latencyMillis)} ms',
          ),
        ),
        cell(
          Text(
            label,
            style: TextStyle(
              color: result == null
                  ? ui.muted
                  : result.state == 'reachable'
                  ? ui.success
                  : ui.warning,
            ),
          ),
        ),
      ],
    );
  }

  Widget _copyButton(String value, String label) => IconButton(
    tooltip: label,
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: value));
      model.message('$label成功');
    },
    icon: const Icon(Icons.content_copy, size: 16),
  );

  Widget _value(BuildContext context, String label, Widget value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      value,
    ],
  );

  Widget _pair(
    Widget main,
    Widget trailing, {
    required double breakpoint,
    Alignment stackedAlignment = Alignment.centerLeft,
  }) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < breakpoint
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              main,
              const SizedBox(height: 12),
              Align(alignment: stackedAlignment, child: trailing),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: main),
              const SizedBox(width: 20),
              trailing,
            ],
          ),
  );

  String _millis(double? value) => value == null
      ? '—'
      : value < 1
      ? value.toStringAsFixed(1)
      : value.round().toString();

  String _taskLabel(DiagnosticOperation? task) {
    if (task == null) return '尚未检测';
    if (!task.finished) return '检测中…';
    if (task.state == 'cancelled') return '已取消，已完成结果保留';
    if (task.state == 'failed') return '检测失败，请重试';
    final time =
        task.result.checkedAt?.toLocal() ??
        task.result.websites.lastOrNull?.checkedAt?.toLocal();
    if (time == null) return '检测完成';
    return '更新于 ${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}
