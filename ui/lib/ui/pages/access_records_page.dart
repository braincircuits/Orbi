import 'package:flutter/material.dart';

import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';

import '../../models/kernel_status.dart';
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
  String filter = '', error = '';
  String stateFilter = '';
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
      cursor = 0;
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
    if (more && (loading || cursor == 0)) return;
    final current = ++request;
    setState(() {
      loading = true;
      error = '';
      if (!more) {
        filter = search.text.trim();
        records = [];
        cursor = 0;
      }
    });
    if (!more && scroll.hasClients) scroll.jumpTo(0);
    try {
      final page = await widget.proxy.accessHistory(
        target: filter,
        state: stateFilter,
        beforeId: more ? cursor : null,
      );
      if (!mounted || current != request) return;
      setState(() {
        records = [...records, ...page.items];
        cursor = page.nextBeforeId;
        loading = false;
      });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = widget.proxy.connected && !loading;
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
                  hintText: '搜索历史域名、IP 或端口',
                  prefixIcon: Icon(
                    Icons.search,
                    size: DesktopDesign.actionIconSize,
                  ),
                ),
                onSubmitted: available ? (_) => _load() : null,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: available ? () => _load() : null,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('查询 / 刷新'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('连接状态'),
            SizedBox(
              width: 168,
              child: DesktopSelect<String>(
                key: const ValueKey('access-state-filter'),
                value: stateFilter,
                options: const [
                  ('', '全部状态'),
                  ('failed', '连接失败'),
                  ('connected', '已建立连接'),
                  ('cancelled', '已取消'),
                  ('pending', '未完成'),
                ],
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
          '长期保存在 SQLite · 已显示 ${records.length} 条 · 最新访问在前',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Text(
          '记录目标地址，不记录网页路径；“已建立连接”不代表网页返回成功。',
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
        if (loading) const LinearProgressIndicator(),
        Expanded(
          key: const ValueKey('access-record-list'),
          child: records.isEmpty && !loading
              ? Center(
                  child: Text(
                    stateFilter.isEmpty && filter.isEmpty
                        ? '暂无访问记录'
                        : '没有符合筛选条件的访问记录',
                  ),
                )
              : SelectionArea(
                  child: ListView.separated(
                    controller: scroll,
                    key: const PageStorageKey('access-records'),
                    itemCount: records.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = records[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.target,
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 5),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                Text(
                                  entry.createdAt.toString().split('.').first,
                                  style: theme.textTheme.bodySmall,
                                ),
                                Text(
                                  '原始 ${entry.originalProtocolLabel}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                Text(
                                  '${entry.method} · ${entry.routeLabel} · ${entry.protocolLabel}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                Text(
                                  entry.stateLabel,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                            Text(
                              '来源 ${entry.source}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (cursor > 0 && error.isNotEmpty)
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
