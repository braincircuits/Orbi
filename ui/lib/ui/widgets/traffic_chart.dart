import 'package:flutter/material.dart';

import '../../models/traffic_summary.dart';
import '../../services/proxy_controller.dart';
import 'traffic_summary_chart.dart';

/// 分钟趋势读取持久化窗口，仅跨分钟、连接变化及手动刷新时请求。
class TrafficChart extends StatefulWidget {
  const TrafficChart({super.key, required this.proxy});
  final ProxyController proxy;
  @override
  State<TrafficChart> createState() => _TrafficChartState();
}

class _TrafficChartState extends State<TrafficChart> {
  TrafficSummary? summary;
  String error = '';
  int hours = 1, request = 0;
  bool loading = false;
  (bool, bool, int, String?, int)? observed;
  @override
  void initState() {
    super.initState();
    widget.proxy.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(TrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.proxy != widget.proxy) {
      oldWidget.proxy.removeListener(_changed);
      widget.proxy.addListener(_changed);
      observed = null;
      summary = null;
      _changed();
    }
  }

  void _changed() {
    final next = (
      widget.proxy.connected,
      widget.proxy.running,
      widget.proxy.kernelGeneration,
      widget.proxy.traffic?.sessionId,
      (widget.proxy.traffic?.current.sampledAt ??
              DateTime.now().millisecondsSinceEpoch) ~/
          60000,
    );
    if (next == observed) return;
    observed = next;
    if (!next.$1) {
      request++;
      setState(() => loading = false);
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final current = ++request;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final value = await widget.proxy.trafficSummary(hourly: false);
      if (!mounted || current != request) return;
      setState(() {
        summary = value;
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
  void dispose() {
    widget.proxy.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('流量趋势', style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<int>(
              key: const ValueKey('traffic-range'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1 小时')),
                ButtonSegment(value: 6, label: Text('6 小时')),
                ButtonSegment(value: 24, label: Text('24 小时')),
              ],
              selected: {hours},
              onSelectionChanged: (value) =>
                  setState(() => hours = value.single),
            ),
            IconButton(
              tooltip: '刷新趋势',
              onPressed: widget.proxy.connected && !loading ? _load : null,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (loading && data == null) const LinearProgressIndicator(),
        if (!widget.proxy.connected) const Text('内核未连接，保留最近读取的分钟趋势。'),
        if (error.isNotEmpty)
          Text(
            '趋势加载失败：$error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (data != null)
          TrafficSummaryChart(summary: data, from: data.to - hours * 3600000),
        const SizedBox(height: 8),
        Text(
          '每分钟结束时保存 · 保留最近 24 小时${data == null ? '' : ' · ${data.zoneId}'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
