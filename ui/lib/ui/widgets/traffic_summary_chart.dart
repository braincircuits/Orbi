import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/traffic_summary.dart';
import '../desktop_theme.dart';
import 'traffic_chart.dart';

/// 历史图展示每段字节总量，不把累计流量当作瞬时速率连线。
class TrafficSummaryChart extends StatefulWidget {
  const TrafficSummaryChart({
    super.key,
    required this.summary,
    required this.window,
    required this.onOpen,
  });
  final TrafficSummary summary;
  final TrafficWindow window;
  final ValueChanged<TrafficBucket> onOpen;
  @override
  State<TrafficSummaryChart> createState() => _TrafficSummaryChartState();
}

class _TrafficSummaryChartState extends State<TrafficSummaryChart> {
  int? selected;
  @override
  void didUpdateWidget(TrafficSummaryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary != widget.summary) selected = null;
  }

  String range(TrafficBucket bucket) =>
      '${trafficDate(bucket.from)} ${trafficTime(bucket.from)} ${bucket.from.timeZoneName} → '
      '${trafficDate(bucket.to)} ${trafficTime(bucket.to)} ${bucket.to.timeZoneName}';
  String details(TrafficBucket bucket) => bucket.from.isAfter(DateTime.now())
      ? '尚未到达'
      : bucket.sampleCount == 0
      ? '无采样记录'
      : '发送 ${formatTrafficBytes(bucket.sentBytes)} · 接收 ${formatTrafficBytes(bucket.receivedBytes)}';
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buckets = widget.summary.buckets;
    final up = DesktopDesign.trafficSend(theme.brightness);
    final down = DesktopDesign.trafficReceive(theme.brightness);
    final maximum =
        buckets.fold<int>(
          1,
          (v, b) => math.max(v, math.max(b.sentBytes, b.receivedBytes)),
        ) *
        1.15;
    final index = selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 4,
          children: [
            Text('● 发送', style: TextStyle(color: up)),
            Text('● 接收', style: TextStyle(color: down)),
            Text(
              '每${widget.window.period.bucketLabel}流量 · 代理与直连',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 188,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 62,
                height: 160,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatTrafficBytes(maximum),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      formatTrafficBytes(maximum / 2),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text('0 B', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final step = math.max(
                      1,
                      (buckets.length / (width < 400 ? 4 : 8)).ceil(),
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final top in [0.0, 80.0, 160.0])
                          Positioned(
                            left: 0,
                            right: 0,
                            top: top,
                            child: Divider(
                              height: 1,
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < buckets.length; i++)
                              Expanded(
                                child: Tooltip(
                                  message:
                                      '${range(buckets[i])}\n${details(buckets[i])}',
                                  waitDuration: const Duration(
                                    milliseconds: 200,
                                  ),
                                  child: InkWell(
                                    key: ValueKey('traffic-bucket-$i'),
                                    onHover: (hover) {
                                      if (hover) setState(() => selected = i);
                                    },
                                    onFocusChange: (focus) {
                                      if (focus) setState(() => selected = i);
                                    },
                                    onTap:
                                        buckets[i].from.isAfter(DateTime.now())
                                        ? null
                                        : () {
                                            setState(() => selected = i);
                                            widget.onOpen(buckets[i]);
                                          },
                                    child: Semantics(
                                      label:
                                          '${range(buckets[i])}，${details(buckets[i])}',
                                      child: Container(
                                        height: 161,
                                        color: selected == i
                                            ? theme.colorScheme.primary
                                                  .withValues(alpha: 0.08)
                                            : null,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        child: buckets[i].sampleCount == 0
                                            ? Align(
                                                alignment:
                                                    Alignment.bottomCenter,
                                                child: Container(
                                                  height: 3,
                                                  color: theme
                                                      .colorScheme
                                                      .outlineVariant,
                                                ),
                                              )
                                            : Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Expanded(
                                                    child: Container(
                                                      height: math.max(
                                                        1,
                                                        160 *
                                                            buckets[i]
                                                                .sentBytes /
                                                            maximum,
                                                      ),
                                                      color: up,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 1),
                                                  Expanded(
                                                    child: Container(
                                                      height: math.max(
                                                        1,
                                                        160 *
                                                            buckets[i]
                                                                .receivedBytes /
                                                            maximum,
                                                      ),
                                                      color: down,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        for (var i = 0; i < buckets.length; i += step)
                          Positioned(
                            top: 166,
                            left: (width * i / buckets.length).clamp(
                              0,
                              math.max(0, width - 35),
                            ),
                            child: Text(switch (widget.window.period) {
                              TrafficPeriod.hour =>
                                '${buckets[i].from.minute.toString().padLeft(2, '0')}分',
                              TrafficPeriod.day => trafficTime(buckets[i].from),
                              TrafficPeriod.month => '${buckets[i].from.day}日',
                            }, style: theme.textTheme.bodySmall),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          index == null
              ? '悬停查看明细${widget.window.period == TrafficPeriod.hour ? '' : '，点击查看该${widget.window.period == TrafficPeriod.month ? '天' : '小时'}'}'
              : range(buckets[index]),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          index == null
              ? '灰色短线表示无采样记录；有采样但无流量显示为 0 B。'
              : details(buckets[index]),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
