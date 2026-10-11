import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/kernel_status.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/traffic_chart.dart';
import 'traffic_history_dialog.dart';

/// 概览只读展示当前配置；检测统一由内核按实际出口执行。
class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.model, this.onSettings});
  final ProxyViewModel model;
  final VoidCallback? onSettings;

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
        backgroundColor: Color.alphaBlend(
          actionColor.withValues(alpha: .08),
          ui.panel,
        ),
        foregroundColor: running
            ? actionColor
            : Color.lerp(actionColor, ui.ink, .2),
        side: BorderSide(
          color: Color.alphaBlend(actionColor.withValues(alpha: .2), ui.panel),
        ),
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
      ui.card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pair(
              Row(
                children: [
                  ui.dot(running, size: 8),
                  const SizedBox(width: 10),
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
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        small('${running ? '正在使用' : '开启后使用'}$modeLabel模式'),
                      ],
                    ),
                  ),
                ],
              ),
              toggle,
              breakpoint: 500,
              stackedAlignment: Alignment.centerRight,
            ),
            const Divider(height: 28),
            _pair(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('路由模式'),
                  const SizedBox(height: 4),
                  small(switch (proxy.routingMode) {
                    'direct' => '接入流量直接访问目标网站',
                    'proxy' => '接入流量统一经当前服务端转发',
                    _ => '按目标路由和直连规则分流',
                  }),
                ],
              ),
              SizedBox(
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
              breakpoint: 500,
              stackedAlignment: Alignment.centerRight,
            ),
            const SizedBox(height: 10),
            small('仅作用于接入本地代理的流量；直连／全局模式覆盖路由规则'),
            const Divider(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                small('本地 HTTP 代理'),
                SelectableText(localAddress, style: DesktopDesign.monoText),
                _copyButton(localAddress, '复制本地代理地址'),
                small(running ? '监听中' : '未监听'),
              ],
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
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
                  style: theme.textTheme.titleLarge,
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
                      style: theme.textTheme.titleLarge,
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
                    style: theme.textTheme.titleLarge,
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
            final columns = constraints.maxWidth < 550 ? 2 : 4;
            return Wrap(
              spacing: 16,
              runSpacing: 18,
              children: [
                for (final item in items)
                  SizedBox(
                    width:
                        (constraints.maxWidth - 16 * (columns - 1)) / columns,
                    child: item,
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
      const Divider(height: 32),
      LayoutBuilder(
        builder: (context, constraints) {
          final connectionCard = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ui.heading(direct ? '代理连接 · 当前未使用' : '当前连接'),
              ui.card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pair(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title(connection?.name ?? '尚未配置连接'),
                          const SizedBox(height: 14),
                          small('当前地址'),
                          const SizedBox(height: 4),
                          SelectableText(
                            connection?.endpoint ?? '—',
                            key: const PageStorageKey('overview-endpoint'),
                            style: DesktopDesign.monoText,
                          ),
                          const SizedBox(height: 12),
                          small('传输协议'),
                          const SizedBox(height: 4),
                          Text(
                            connection == null
                                ? '—'
                                : connection.protocol == 'http2'
                                ? 'HTTP/2 · TCP + TLS'
                                : 'HTTP/3 · QUIC',
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          small('服务端连接'),
                          const SizedBox(height: 4),
                          Text(serverState),
                          const SizedBox(height: 12),
                          small('最近延迟检测'),
                          const SizedBox(height: 4),
                          small(
                            direct
                                ? '直连模式未使用'
                                : !running
                                ? '开启后可检测'
                                : _taskLabel(latency),
                          ),
                        ],
                      ),
                      breakpoint: 480,
                    ),
                    const Divider(height: 24),
                    small('在「连接配置」中修改或切换连接'),
                  ],
                ),
              ),
            ],
          );
          final exitCard = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ui.heading('出口信息'),
              ui.card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pair(
                      title(
                        '出口 IP · ${proxy.routingMode == 'rules' ? '按规则查询' : '$modeLabel出口'}',
                      ),
                      TextButton.icon(
                        onPressed: canTest && !proxy.overviewBusy('exit-ip')
                            ? () => model.startOverview('exit-ip')
                            : null,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(
                          proxy.overviewBusy('exit-ip') ? '获取中…' : '刷新',
                        ),
                      ),
                      breakpoint: 330,
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final result = ip?.state == 'succeeded'
                            ? ip!.result
                            : null;
                        final location = {
                          result?.country ?? '',
                          result?.region ?? '',
                          result?.city ?? '',
                        }.where((v) => v.isNotEmpty).join(' · ');
                        final values = [
                          _value(
                            context,
                            '公网 IP',
                            Row(
                              mainAxisSize: MainAxisSize.min,
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
                        ];
                        if (constraints.maxWidth < 600) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              values[0],
                              const SizedBox(height: 14),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: values[1]),
                                  const SizedBox(width: 16),
                                  Expanded(child: values[2]),
                                ],
                              ),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < values.length; i++) ...[
                              if (i > 0) const SizedBox(width: 16),
                              Expanded(child: values[i]),
                            ],
                          ],
                        );
                      },
                    ),
                    const Divider(height: 24),
                    small(!running ? '开启服务后可获取' : _taskLabel(ip)),
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
                ),
              ),
            ],
          );
          return constraints.maxWidth < 760
              ? Column(
                  children: [
                    connectionCard,
                    const SizedBox(height: 18),
                    exitCard,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: connectionCard),
                    const SizedBox(width: 16),
                    Expanded(child: exitCard),
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
