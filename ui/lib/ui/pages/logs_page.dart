import 'package:flutter/material.dart';

import '../../view_models/proxy_view_model.dart';
import '../widgets/desktop_widgets.dart';
import '../widgets/desktop_select.dart';
import '../desktop_theme.dart';

class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.model});
  final ProxyViewModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model.proxy.logChanges,
    builder: (context, _) => _content(context, DesktopWidgets(context, model)),
  );
  String _logTime(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return '客户端';
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
  }

  Widget _content(BuildContext context, DesktopWidgets ui) {
    final source = model.pauseLogs ? model.pausedLines : model.proxy.logs;
    final lines = source
        .where((log) => model.filter == '全部' || log.level == model.filter)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ui.pageHeading('运行日志', '最近采集记录 · 按级别精确筛选'),
        Row(
          children: [
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
            const SizedBox(width: 12),
            Text(
              '${lines.length} 条',
              style: TextStyle(color: ui.muted, fontSize: 11),
            ),
            const Spacer(),
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
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: lines.isEmpty ? null : () => model.exportLogs(lines),
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导出'),
            ),
          ],
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
                    '暂无日志',
                    '启动代理后将在这里显示运行记录',
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
