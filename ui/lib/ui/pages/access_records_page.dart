import 'package:flutter/material.dart';

import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';
import '../widgets/sortable_table.dart';

import '../../models/kernel_status.dart';
import '../../models/database_settings.dart';
import '../../services/proxy_controller.dart';

/// 按数据库游标加载历史，滚动接近底部时自动加载下一页。
class AccessRecordsPage extends StatefulWidget {
  const AccessRecordsPage({super.key, required this.proxy});
  final ProxyController proxy;
  @override
  State<AccessRecordsPage> createState() => _AccessRecordsPageState();
}

class _AccessRecordsPageState extends State<AccessRecordsPage> {
  final search = TextEditingController();
  final scroll = ScrollController();
  List<AccessRecord> records = [];
  final hosts = <String>{};
  String filter = '', error = '';
  String stateFilter = '', cursorHost = '';
  int sortColumn = 2;
  bool ascending = false;
  String get order => const ['host', 'count', 'recent', 'failure'][sortColumn];
  bool hasMore = false;
  int cursor = 0, request = 0, generation = 0;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    generation = widget.proxy.kernelGeneration;
    scroll.addListener(_loadNearBottom);
    _load();
  }

  @override
  void didUpdateWidget(AccessRecordsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (generation != widget.proxy.kernelGeneration) {
      generation = widget.proxy.kernelGeneration;
      request++;
      records = [];
      hosts.clear();
      cursor = 0;
      cursorHost = '';
      hasMore = false;
      loading = false;
      if (widget.proxy.connected) _load();
    }
  }

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _loadNearBottom() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 120 &&
        error.isEmpty) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!widget.proxy.connected) return;
    if (more && (loading || !hasMore)) return;
    final current = ++request;
    setState(() {
      loading = true;
      error = '';
      if (!more) {
        filter = search.text.trim();
        cursor = 0;
        cursorHost = '';
        hasMore = false;
      }
    });
    try {
      final page = await widget.proxy.accessHistory(
        target: filter,
        failedOnly: stateFilter == 'failed',
        order: order,
        ascending: ascending,
        beforeValue: more ? cursor : null,
        afterHost: more ? cursorHost : '',
      );
      if (!mounted || current != request) return;
      setState(() {
        // 查询完成前保留当前列表，成功后再一次性替换。
        if (!more) {
          records = [];
          hosts.clear();
        }
        // 使用集合去重并原地追加，避免每页扫描、复制全部已加载记录。
        for (final item in page.items) {
          if (hosts.add(item.host)) records.add(item);
        }
        cursor = page.nextValue;
        cursorHost = page.nextHost;
        hasMore = page.hasMore;
        loading = false;
      });
      if (!more && scroll.hasClients) scroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadNearBottom();
      });
    } catch (failure) {
      if (!mounted || current != request) return;
      setState(() {
        error = widget.proxy.redact('$failure');
        loading = false;
      });
    }
  }

  String _time(int value) => value == 0
      ? '—'
      : DateTime.fromMillisecondsSinceEpoch(value).toString().split('.').first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = widget.proxy.connected;
    // 各列均为单行，固定行高后拖动滚动条无需测量中间的几千行。
    final rowHeight =
        48 *
        (MediaQuery.textScalerOf(context).scale(DesktopDesign.bodyFontSize) /
                DesktopDesign.bodyFontSize)
            .clamp(1.0, double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('access-search'),
                controller: search,
                decoration: const InputDecoration(
                  hintText: '搜索域名或 IP',
                  prefixIcon: Icon(
                    Icons.search,
                    size: DesktopDesign.actionIconSize,
                  ),
                ),
                onSubmitted: available ? (_) => _load() : null,
              ),
            ),
            const SizedBox(width: 12),
            // 与实时隧道的路由筛选框等宽，切换页签时保持搜索框边界不变。
            SizedBox(
              width: 128,
              child: OutlinedButton.icon(
                onPressed: available
                    ? () {
                        if (!loading) _load();
                      }
                    : null,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('查询 / 刷新'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('访问筛选'),
            SizedBox(
              width: 168,
              child: DesktopSelect<String>(
                key: const ValueKey('access-state-filter'),
                value: stateFilter,
                options: const [('', '全部域名'), ('failed', '曾经失败')],
                onSelected: available
                    ? (value) {
                        if (value == null || value == stateFilter) return;
                        stateFilter = value;
                        _load();
                      }
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '长期保存在 ${DatabaseSettings.labels[widget.proxy.storageBackend] ?? '数据库'} · 已显示 ${records.length} 个域名 / IP',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Text(
          '按连接尝试累计，每分钟保存；同一域名的端口、协议和路由合并统计。',
          style: theme.textTheme.bodySmall,
        ),
        if (!widget.proxy.connected)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('内核未连接，暂时无法查询历史记录。'),
          ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        if (widget.proxy.historyStorageWarning.isNotEmpty)
          Text(
            widget.proxy.historyStorageWarning,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        SizedBox(
          height: 4,
          child: loading ? const LinearProgressIndicator() : null,
        ),
        Expanded(
          key: const ValueKey('access-record-list'),
          child: SortableTable(
            columns: const ['域名 / IP', '连接次数', '最后访问时间', '最后失败时间'],
            widths: const [280, 120, 210, 210],
            sortColumn: sortColumn,
            ascending: ascending,
            onSort: widget.proxy.connected
                ? (column) {
                    ascending = sortColumn == column ? !ascending : true;
                    sortColumn = column;
                    _load();
                  }
                : null,
            controller: scroll,
            listKey: const PageStorageKey('access-records'),
            rowCount: records.length,
            itemExtent: rowHeight,
            rowKey: (index) => records[index].host,
            empty: Center(
              child: Text(
                loading
                    ? '正在加载访问记录…'
                    : stateFilter.isEmpty && filter.isEmpty
                    ? '暂无访问记录'
                    : '没有符合筛选条件的访问记录',
              ),
            ),
            cells: (index) {
              final entry = records[index];
              return [
                TableText(entry.host),
                TableText('${entry.connectionCount}'),
                TableText(_time(entry.lastAccessAt)),
                TableText(_time(entry.lastFailureAt)),
              ];
            },
          ),
        ),
        if (hasMore && error.isNotEmpty)
          Align(
            alignment: Alignment.center,
            child: TextButton(
              onPressed: available ? () => _load(more: true) : null,
              child: const Text('重试加载'),
            ),
          ),
      ],
    );
  }
}
