import 'package:flutter/material.dart';

import '../../models/kernel_status.dart';
import '../../view_models/proxy_view_model.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';
import '../widgets/desktop_widgets.dart';
import 'access_records_page.dart';

class TunnelsPage extends StatefulWidget {
  const TunnelsPage({super.key, required this.model});
  final ProxyViewModel model;

  @override
  State<TunnelsPage> createState() => _TunnelsPageState();
}

class _TunnelsPageState extends State<TunnelsPage> {
  String query = '', route = 'all';
  bool history = false;

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
            minimumSize: const Size(0, 28),
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
            width: 100,
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
          onSelectionChanged: (value) => setState(() => history = value.single),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: history
              ? AccessRecordsPage(proxy: widget.model.proxy)
              : _live(context),
        ),
      ],
    );
  }

  Widget _live(BuildContext context) {
    final ui = DesktopWidgets(context, widget.model);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('tunnel-search'),
                    decoration: const InputDecoration(
                      hintText: '搜索目标、来源或连接名称',
                      prefixIcon: Icon(
                        Icons.search,
                        size: DesktopDesign.actionIconSize,
                      ),
                    ),
                    onChanged: (value) => setState(() => query = value),
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
                listenable: widget.model.tunnelChanges,
                builder: (context, _) => _tunnelList(context, ui, wide),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '点击路由可切换该域名或 IP 的所有端口，规则自动保存；路由变化的连接会断开重连。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  Widget _tunnelList(BuildContext context, DesktopWidgets ui, bool wide) {
    final proxy = widget.model.proxy;
    final all = proxy.tunnels;
    final search = query.trim().toLowerCase();
    final entries = all
        .where(
          (tunnel) =>
              (route == 'all' || tunnel.route == route) &&
              '${tunnel.target} ${tunnel.source} ${tunnel.profileName}'
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    final active = proxy.activeTunnelCount;
    final indices = {
      for (final (index, tunnel) in entries.indexed) tunnel.id: index,
    };
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
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: ui.panel,
              border: Border.all(color: ui.line),
              borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
            ),
            child: entries.isEmpty
                ? ui.empty(
                    Icons.swap_vert,
                    all.isEmpty ? '暂无隧道' : '没有匹配的隧道',
                    all.isEmpty ? '代理请求到达后，会在这里显示当前连接' : '调整搜索内容或路由筛选',
                  )
                : SelectionArea(
                    child: Column(
                      children: [
                        if (wide)
                          Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Expanded(child: _text('目标地址', muted: true)),
                                SizedBox(
                                  width: 80,
                                  child: _text('原始协议', muted: true),
                                ),
                                SizedBox(
                                  width: 176,
                                  child: _text('来源地址', muted: true),
                                ),
                                SizedBox(
                                  width: 156,
                                  child: _text('路由 / 协议', muted: true),
                                ),
                                SizedBox(
                                  width: 104,
                                  child: _text('状态', muted: true),
                                ),
                                SizedBox(
                                  width: 88,
                                  child: _text('开始时间', muted: true),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            child: ListView.builder(
                              key: const PageStorageKey('tunnels'),
                              itemCount: entries.length,
                              findChildIndexCallback: (key) =>
                                  key is ValueKey<String>
                                  ? indices[key.value]
                                  : null,
                              itemBuilder: (context, index) {
                                final tunnel = entries[index];
                                return Container(
                                  key: ValueKey(tunnel.id),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: ui.line),
                                    ),
                                  ),
                                  child: wide
                                      ? Row(
                                          children: [
                                            Expanded(
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 16,
                                                ),
                                                child: _text(tunnel.target),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 80,
                                              child: _text(
                                                tunnel.originalProtocolLabel,
                                              ),
                                            ),
                                            SizedBox(
                                              width: 176,
                                              child: _text(
                                                tunnel.source,
                                                muted: true,
                                              ),
                                            ),
                                            SizedBox(
                                              width: 156,
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 12,
                                                ),
                                                child: _routeControl(tunnel),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 104,
                                              child: _state(tunnel, ui),
                                            ),
                                            SizedBox(
                                              width: 88,
                                              child: _createdAt(tunnel),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: _text(tunnel.target),
                                                ),
                                                const SizedBox(width: 12),
                                                _routeControl(tunnel),
                                                const SizedBox(width: 8),
                                                SizedBox(
                                                  width: 76,
                                                  child: _state(tunnel, ui),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              children: [
                                                _text(
                                                  '原始 ${tunnel.originalProtocolLabel}',
                                                  muted: true,
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: _text(
                                                    tunnel.source,
                                                    muted: true,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                _createdAt(tunnel),
                                              ],
                                            ),
                                          ],
                                        ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
