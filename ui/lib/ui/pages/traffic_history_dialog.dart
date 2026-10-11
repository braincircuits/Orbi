import 'package:flutter/material.dart';

import '../../models/traffic_summary.dart';
import '../../services/proxy_controller.dart';
import '../desktop_theme.dart';
import '../widgets/desktop_select.dart';
import '../widgets/traffic_chart.dart';
import '../widgets/traffic_summary_chart.dart';

class TrafficHistoryDialog extends StatefulWidget {
  const TrafficHistoryDialog({super.key, required this.proxy});
  final ProxyController proxy;
  @override
  State<TrafficHistoryDialog> createState() => _TrafficHistoryDialogState();
}

class _TrafficHistoryDialogState extends State<TrafficHistoryDialog> {
  TrafficWindow window = TrafficWindow(TrafficPeriod.day, DateTime.now());
  TrafficSummary? summary;
  String error = '';
  bool loading = false;
  int request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([TrafficWindow? next]) async {
    final current = ++request;
    setState(() {
      if (next != null) window = next;
      loading = true;
      summary = null;
      error = '';
    });
    try {
      final result = await widget.proxy.trafficSummary(window);
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    DateTime? value;
    if (window.period == TrafficPeriod.month) {
      var year = window.start.year;
      value = await showDialog<DateTime>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Row(
              children: [
                IconButton(
                  tooltip: '上一年',
                  onPressed: year > 1971 ? () => update(() => year--) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(child: Text('$year 年', textAlign: TextAlign.center)),
                IconButton(
                  tooltip: '下一年',
                  onPressed: year < now.year
                      ? () => update(() => year++)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var month = 1; month <= 12; month++)
                    SizedBox(
                      width: 86,
                      child: OutlinedButton(
                        onPressed: DateTime(year, month).isAfter(now)
                            ? null
                            : () =>
                                  Navigator.pop(context, DateTime(year, month)),
                        child: Text('$month 月'),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      );
    } else {
      value = await showDatePicker(
        context: context,
        initialDate: window.start,
        firstDate: DateTime(1971),
        lastDate: now,
        helpText: '选择统计日期',
        cancelText: '取消',
        confirmText: '确定',
      );
    }
    if (!mounted || value == null) return;
    var anchor = DateTime(
      value.year,
      value.month,
      value.day,
      window.period == TrafficPeriod.hour ? window.start.hour : 0,
    );
    if (anchor.isAfter(now)) anchor = now;
    _load(TrafficWindow(window.period, anchor));
  }

  void _open(TrafficBucket bucket) {
    final period = switch (window.period) {
      TrafficPeriod.month => TrafficPeriod.day,
      TrafficPeriod.day => TrafficPeriod.hour,
      TrafficPeriod.hour => null,
    };
    if (period != null) _load(TrafficWindow(period, bucket.from));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = summary;
    final now = DateTime.now();
    final today = TrafficWindow(window.period, now);
    final current = window.start == today.start;
    final hours = TrafficWindow(TrafficPeriod.day, window.start).boundaries;
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
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭历史流量',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<TrafficPeriod>(
                            key: const ValueKey('history-period'),
                            showSelectedIcon: false,
                            segments: [
                              for (final period in TrafficPeriod.values)
                                ButtonSegment(
                                  value: period,
                                  label: Text(period.label),
                                ),
                            ],
                            selected: {window.period},
                            onSelectionChanged: (values) => _load(
                              TrafficWindow(values.single, window.anchor),
                            ),
                          ),
                          Text(
                            '按${window.period.bucketLabel}统计 · 长期保留',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '上一${window.period.label}',
                            onPressed: window.shift(-1).start.year >= 1971
                                ? () => _load(window.shift(-1))
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('history-date'),
                            onPressed: _pickDate,
                            icon: const Icon(
                              Icons.calendar_month_outlined,
                              size: 18,
                            ),
                            label: Text(window.title),
                          ),
                          IconButton(
                            tooltip: '下一${window.period.label}',
                            onPressed: window.shift(1).start.isAfter(now)
                                ? null
                                : () => _load(window.shift(1)),
                            icon: const Icon(Icons.chevron_right),
                          ),
                          if (window.period == TrafficPeriod.hour)
                            SizedBox(
                              width: 150,
                              child: DesktopSelect<DateTime>(
                                value: window.start,
                                options: [
                                  for (final hour in hours.take(
                                    hours.length - 1,
                                  ))
                                    if (!hour.isAfter(now))
                                      (
                                        hour,
                                        '${trafficTime(hour)} ${hour.timeZoneName}',
                                      ),
                                ],
                                onSelected: (value) {
                                  if (value != null) {
                                    _load(TrafficWindow(window.period, value));
                                  }
                                },
                              ),
                            ),
                          TextButton(
                            onPressed: current ? null : () => _load(today),
                            child: Text(window.period.currentLabel),
                          ),
                          IconButton(
                            tooltip: '刷新统计',
                            onPressed: loading ? null : () => _load(),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '本地时间 · ${now.timeZoneName} · 包含历次运行记录',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      if (loading) const LinearProgressIndicator(),
                      if (error.isNotEmpty) ...[
                        Text(
                          '统计加载失败：$error',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        TextButton(
                          onPressed: () => _load(),
                          child: const Text('重试'),
                        ),
                      ],
                      if (data != null) ...[
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
                        if (data.sampleCount == 0)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: Text('此时间段暂无采样记录'),
                          ),
                        TrafficSummaryChart(
                          summary: data,
                          window: window,
                          onOpen: _open,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          current
                              ? '当前时间段尚未结束，显示已保存数据；点击刷新更新统计。'
                              : '显示所选时间段的已保存流量。',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (data.lastSampledAt > 0)
                          Text(
                            '采样截至：${DateTime.fromMillisecondsSinceEpoch(data.lastSampledAt).toString().split('.').first}',
                            style: theme.textTheme.bodySmall,
                          ),
                        Text(
                          '包含代理与直连流量；无采样记录的时间段不作估算。',
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
