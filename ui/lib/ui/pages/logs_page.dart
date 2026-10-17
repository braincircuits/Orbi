import 'package:flutter/material.dart';

import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/desktop_select.dart';
import '../desktop_theme.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.model, this.visible = true});
  final ProxyViewModel model;
  final bool visible;
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final search = TextEditingController();
  ProxyViewModel get model => widget.model;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void _searchChanged() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && model.logScroll.hasClients) model.logScroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // 隐藏或暂停时保留列表状态，仅在重新显示时读取最新缓存。
    listenable: Listenable.merge([
      if (widget.visible && !model.pauseLogs) model.proxy.logChanges,
    ]),
    builder: (context, _) => _content(context, DesktopWidgets(context, model)),
  );
  String _logTime(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return '客户端';
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  }

  Widget _content(BuildContext context, DesktopWidgets ui) {
    final source = model.pauseLogs ? model.pausedLines : model.proxy.logs;
    final query = search.text.trim().toLowerCase();
    final lines = source
        .where(
          (log) =>
              (model.filter == '全部' || log.level == model.filter) &&
              log.message.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth < 620 ? constraints.maxWidth : 260,
                child: TextField(
                  key: const ValueKey('log-search'),
                  controller: search,
                  onChanged: (_) => _searchChanged(),
                  decoration: InputDecoration(
                    hintText: '搜索日志内容',
                    prefixIcon: const Icon(
                      Icons.search,
                      size: DesktopDesign.actionIconSize,
                    ),
                    suffixIcon: IconButton(
                      tooltip: '清空日志搜索',
                      onPressed: search.text.isEmpty
                          ? null
                          : () {
                              search.clear();
                              _searchChanged();
                            },
                      icon: const Icon(
                        Icons.close,
                        size: DesktopDesign.actionIconSize,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 132,
                child: DesktopSelect<String>(
                  value: model.filter,
                  options: [
                    for (final level in [
                      '全部',
                      'TRACE',
                      'DEBUG',
                      'INFO',
                      'WARN',
                      'ERROR',
                      'FATAL',
                    ])
                      (level, level == '全部' ? '所有级别' : level),
                  ],
                  onSelected: (value) {
                    if (value != null) model.update(() => model.filter = value);
                  },
                ),
              ),
              Text(
                '${lines.length} / ${source.length} 条',
                style: TextStyle(color: ui.muted, fontSize: 11),
              ),
              IconButton(
                tooltip: model.pauseLogs ? '恢复日志' : '暂停日志',
                onPressed: model.toggleLogPause,
                icon: Icon(model.pauseLogs ? Icons.play_arrow : Icons.pause),
              ),
              IconButton(
                tooltip: '清空显示',
                onPressed: model.clearLogs,
                icon: const Icon(Icons.delete_outline),
              ),
              OutlinedButton.icon(
                onPressed: lines.isEmpty ? null : () => model.exportLogs(lines),
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('导出'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: ui.panel,
              border: Border.all(color: ui.line, width: .5),
              borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
            ),
            child: lines.isEmpty
                ? ui.empty(
                    Icons.description_outlined,
                    source.isEmpty ? '暂无日志' : '没有匹配的日志',
                    source.isEmpty ? '启动代理后将在这里显示运行记录' : '调整关键词或日志级别，原始记录保留',
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: model.logScroll,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: lines.length,
                      itemBuilder: (_, index) {
                        final entry = lines[index];
                        final levelColor =
                            {
                              'ERROR': ui.error,
                              'FATAL': ui.error,
                              'WARN': ui.warning,
                            }[entry.level] ??
                            ui.muted;
                        return Container(
                          color: index.isEven
                              ? ui.muted.withValues(alpha: .04)
                              : null,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 84,
                                child: Text(
                                  _logTime(entry.time),
                                  style: DesktopDesign.monoText.copyWith(
                                    color: ui.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 56,
                                child: Text(
                                  entry.level,
                                  style: DesktopDesign.monoText.copyWith(
                                    color: levelColor,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.message,
                                  style: DesktopDesign.monoText.copyWith(
                                    color: ui.ink,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            Text(
              model.pauseLogs ? '显示已暂停，内核继续记录' : '保留最近 500 条记录',
              style: TextStyle(color: ui.muted, fontSize: 11),
            ),
            const Spacer(),
            if (!model.followLogs && !model.pauseLogs)
              TextButton(
                onPressed: () {
                  model.update(() => model.followLogs = true);
                  model.scrollToLatest();
                },
                child: const Text('跳到最新'),
              ),
          ],
        ),
      ],
    );
  }
}
