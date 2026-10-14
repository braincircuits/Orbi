import 'package:flutter/material.dart';

import '../../models/traffic_summary.dart';
import '../../services/proxy_controller.dart';
import '../desktop_theme.dart';
import '../traffic_format.dart';
import '../widgets/traffic_summary_chart.dart';

class TrafficHistoryDialog extends StatefulWidget {
  const TrafficHistoryDialog({super.key, required this.proxy});
  final ProxyController proxy;
  @override
  State<TrafficHistoryDialog> createState() => _TrafficHistoryDialogState();
}

class _TrafficHistoryDialogState extends State<TrafficHistoryDialog> {
  TrafficSummary? summary;
  String error = '';
  bool loading = false;
  int request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final current = ++request;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.proxy.trafficSummary();
      if (!mounted || current != request) return;
      setState(() {
        summary = result;
        loading = false;
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
    final data = summary;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 740),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('历史流量', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '刷新统计',
                    onPressed: loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '关闭历史流量',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '最近 1 个月 · 按小时统计 · 保留最近 12 个月',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      if (loading) const LinearProgressIndicator(),
                      if (error.isNotEmpty) ...[
                        Text(
                          '统计加载失败：$error',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                      if (data != null) ...[
                        Text(
                          '内核时区 · ${data.zoneId}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 24,
                          runSpacing: 12,
                          children: [
                            _metric(
                              '发送流量',
                              data.sentBytes,
                              DesktopDesign.trafficSend(theme.brightness),
                            ),
                            _metric(
                              '接收流量',
                              data.receivedBytes,
                              DesktopDesign.trafficReceive(theme.brightness),
                            ),
                            _metric(
                              '合计流量',
                              data.sentBytes + data.receivedBytes,
                              theme.colorScheme.onSurface,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (data.recordCount == 0) const Text('最近一个月暂无小时记录'),
                        TrafficSummaryChart(summary: data),
                        const SizedBox(height: 16),
                        Text(
                          '仅显示已完成小时；每个整点汇总上一小时，未记录时段不作估算。',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          '过期历史在内核启动时及每天凌晨 03:00 清理。',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (widget.proxy.historyStorageWarning.isNotEmpty)
                        Text(
                          widget.proxy.historyStorageWarning,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, int bytes, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(
        formatTrafficBytes(bytes),
        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color),
      ),
    ],
  );
}
