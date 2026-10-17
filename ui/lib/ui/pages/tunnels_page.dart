import 'package:flutter/material.dart';

import '../../models/kernel_status.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/sortable_table.dart';
import 'access_records_page.dart';

class TunnelsPage extends StatefulWidget {
  const TunnelsPage({super.key, required this.model, this.visible = true});
  final ProxyViewModel model;
  final bool visible;

  @override
  State<TunnelsPage> createState() => _TunnelsPageState();
}

class _TunnelsPageState extends State<TunnelsPage> {
  final search = TextEditingController();
  String route = 'all';
  bool history = false;
  bool historyOpened = false;
  int sortColumn = 5;
  bool ascending = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  String _time(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';

  Widget _text(String value, {bool muted = false}) => Tooltip(
    message: value,
    child: Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: muted ? Theme.of(context).textTheme.bodySmall : null,
    ),
  );

  Widget _state(TunnelStatus tunnel, DesktopWidgets ui) => Row(
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: tunnel.state == 'active' ? ui.success : ui.warning,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 6),
      _text(tunnel.stateLabel),
    ],
  );

  Widget _createdAt(TunnelStatus tunnel) => Tooltip(
    message: tunnel.createdAt.toString(),
    child: Text(
      _time(tunnel.createdAt),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );

  Widget _routeControl(TunnelStatus tunnel) {
    final model = widget.model;
    final scheme = Theme.of(context).colorScheme;
    final enabled = model.proxy.connected && !model.locked;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: Theme.of(context).menuTheme.style!
          .copyWith(minimumSize: const WidgetStatePropertyAll(Size(192, 0))),
      menuChildren: [
        for (final (value, label, icon) in const [
          ('proxy', '切换为代理', Icons.cloud_outlined),
          ('direct', '切换为直连', Icons.alt_route),
          ('auto', '恢复自动路由', Icons.auto_mode),
        ]) ...[
          if (value == 'auto')
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Divider(),
            ),
          MenuItemButton(
            onPressed: enabled
                ? () => model.routeTarget(tunnel.target, value)
                : null,
            leadingIcon: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            child: Text(label),
          ),
        ],
      ],
      builder: (context, controller, _) => Tooltip(
        message: !model.proxy.connected
            ? '请先连接代理内核'
            : model.locked
            ? '正在处理，请稍候'
            : '设置该域名或 IP 的所有端口；路由变化的连接会断开重连',
        child: TextButton.icon(
          key: ValueKey('tunnel-route-${tunnel.id}'),
          onPressed: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, DesktopDesign.controlHeight),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            alignment: Alignment.centerLeft,
            foregroundColor: scheme.onSurface,
            textStyle: const TextStyle(
              fontFamily: DesktopDesign.fontFamily,
              fontFamilyFallback: DesktopDesign.fontFamilyFallback,
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
            backgroundColor: controller.isOpen ? scheme.primaryContainer : null,
          ),
          icon: Icon(
            controller.isOpen ? Icons.expand_less : Icons.expand_more,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          iconAlignment: IconAlignment.end,
          label: SizedBox(
            width: 120,
            child: Row(
              children: [
                SizedBox(
                  width: 39,
                  child: Text(
                    tunnel.routeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text(' · '),
                Expanded(
                  child: Text(
                    tunnel.protocolLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('实时隧道')),
            ButtonSegment(value: true, label: Text('访问记录')),
          ],
          selected: {history},
          onSelectionChanged: (value) => setState(() {
            history = value.single;
            if (history) historyOpened = true;
          }),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: IndexedStack(
            index: history ? 1 : 0,
            children: [
              _live(context),
              if (historyOpened)
                AccessRecordsPage(
                  proxy: widget.model.proxy,
                  visible: widget.visible && history,
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _live(BuildContext context) {
    final ui = DesktopWidgets(context, widget.model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('tunnel-search'),
                controller: search,
                decoration: const InputDecoration(
                  hintText: '搜索目标、来源或连接名称',
                  prefixIcon: Icon(
                    Icons.search,
                    size: DesktopDesign.actionIconSize,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 128,
              child: DesktopSelect<String>(
                value: route,
                options: const [
                  ('all', '全部路由'),
                  ('proxy', '代理'),
                  ('direct', '直连'),
                ],
                onSelected: (value) {
                  if (value != null) setState(() => route = value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              if (widget.visible && !history) widget.model.tunnelChanges,
            ]),
            builder: (context, _) => _tunnelList(context, ui),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '点击路由可切换该域名或 IP 的所有端口，规则自动保存；路由变化的连接会断开重连。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _tunnelList(BuildContext context, DesktopWidgets ui) {
    final proxy = widget.model.proxy;
    // 各列均为单行；固定随文字缩放的行高，恢复深处位置时直接定位可见行。
    // 行内路由按钮需要 30 像素，另保留上下内边距和分隔线。
    final rowHeight =
        56 *
        (MediaQuery.textScalerOf(context).scale(DesktopDesign.bodyFontSize) /
                DesktopDesign.bodyFontSize)
            .clamp(1.0, double.infinity);
    final all = proxy.tunnels;
    final query = search.text.trim().toLowerCase();
    final entries = all
        .where(
          (tunnel) =>
              (route == 'all' || tunnel.route == route) &&
              '${tunnel.target} ${tunnel.source} ${tunnel.profileName}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    entries.sort((a, b) {
      final comparison = switch (sortColumn) {
        0 => a.target.toLowerCase().compareTo(b.target.toLowerCase()),
        1 => a.originalProtocolLabel.compareTo(b.originalProtocolLabel),
        2 => a.source.compareTo(b.source),
        3 => '${a.routeLabel} ${a.protocolLabel}'.compareTo(
          '${b.routeLabel} ${b.protocolLabel}',
        ),
        4 => a.stateLabel.compareTo(b.stateLabel),
        _ => a.createdAt.compareTo(b.createdAt),
      };
      // 值相同时使用稳定标识，实时推送不会打乱同组行的顺序。
      return comparison == 0
          ? a.id.compareTo(b.id)
          : (ascending ? comparison : -comparison);
    });
    final active = proxy.activeTunnelCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '共 ${all.length} 条 · 活跃 $active · 等待 ${proxy.pendingTunnelCount}'
          '${entries.length == all.length ? '' : ' · 当前显示 ${entries.length} 条'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!proxy.connected) ...[
          const SizedBox(height: 10),
          ui.notice(
            '内核未连接，列表保留最后一次收到的隧道信息。',
            Icons.warning_amber_outlined,
            warning: true,
          ),
        ],
        const SizedBox(height: 14),
        Expanded(
          child: SortableTable(
            columns: const ['目标地址', '原始协议', '来源地址', '路由 / 协议', '状态', '开始时间'],
            widths: const [300, 100, 176, 170, 110, 120],
            sortColumn: sortColumn,
            ascending: ascending,
            onSort: (column) => setState(() {
              ascending = sortColumn == column ? !ascending : true;
              sortColumn = column;
            }),
            rowCount: entries.length,
            itemExtent: rowHeight,
            rowKey: (index) => entries[index].id,
            listKey: const PageStorageKey('tunnels'),
            empty: ui.empty(
              Icons.swap_vert,
              all.isEmpty ? '暂无隧道' : '没有匹配的隧道',
              all.isEmpty ? '代理请求到达后，会在这里显示当前连接' : '调整搜索内容或路由筛选',
            ),
            cells: (index) {
              final tunnel = entries[index];
              return [
                _text(tunnel.target),
                _text(tunnel.originalProtocolLabel),
                _text(tunnel.source, muted: true),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _routeControl(tunnel),
                ),
                _state(tunnel, ui),
                _createdAt(tunnel),
              ];
            },
          ),
        ),
      ],
    );
  }
}
