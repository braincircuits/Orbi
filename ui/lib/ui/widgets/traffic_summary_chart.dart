import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/traffic_summary.dart';
import '../desktop_theme.dart';
import '../traffic_format.dart';

/// 分钟与小时共用区间流量折线；无记录处断开，有记录的零流量正常连线。
class TrafficSummaryChart extends StatefulWidget {
  const TrafficSummaryChart({super.key, required this.summary, this.from});
  final TrafficSummary summary;
  final int? from;
  @override
  State<TrafficSummaryChart> createState() => _TrafficSummaryChartState();
}

class _TrafficSummaryChartState extends State<TrafficSummaryChart> {
  int? selected;
  bool showSend = true, showReceive = true;
  @override
  void didUpdateWidget(TrafficSummaryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary != widget.summary || oldWidget.from != widget.from) {
      selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 图高和坐标轴随说明文字缩放，日期标签按实际内容增高。
    final labelSize = theme.textTheme.bodySmall!.fontSize!;
    final textScale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(labelSize) / labelSize,
    );
    final plotHeight = 176 * textScale;
    final buckets = widget.summary.buckets
        .where((b) => b.from >= (widget.from ?? widget.summary.from))
        .toList();
    final up = DesktopDesign.trafficSend(theme.brightness),
        down = DesktopDesign.trafficReceive(theme.brightness);
    final maximum =
        buckets.fold<int>(
          1,
          (v, b) => math.max(
            v,
            math.max(
              showSend ? b.sentBytes : 0,
              showReceive ? b.receivedBytes : 0,
            ),
          ),
        ) *
        1.15;
    final index = selected;
    final bucket = index == null || index >= buckets.length
        ? null
        : buckets[index];
    final detail = bucket == null
        ? '悬停或使用左右方向键查看区间流量'
        : '${bucket.label} · ${bucket.recordCount == 0 ? '无记录' : '发送 ${formatTrafficBytes(bucket.sentBytes)} · 接收 ${formatTrafficBytes(bucket.receivedBytes)}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => setState(() => showSend = !showSend),
              icon: Icon(
                showSend ? Icons.show_chart : Icons.visibility_off_outlined,
                color: up,
                size: 16,
              ),
              label: const Text('发送'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => showReceive = !showReceive),
              icon: Icon(
                showReceive ? Icons.show_chart : Icons.visibility_off_outlined,
                color: down,
                size: 16,
              ),
              label: const Text('接收'),
            ),
            Text(
              '每${widget.summary.interval == 'hour' ? '小时' : '分钟'}流量 · 代理与直连',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72 * textScale,
              height: plotHeight,
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
                  void select(double x) {
                    if (buckets.isEmpty || width <= 0) return;
                    final value = ((x / width) * (buckets.length - 1))
                        .round()
                        .clamp(0, buckets.length - 1);
                    if (value != selected) setState(() => selected = value);
                  }

                  return Column(
                    children: [
                      Focus(
                        onKeyEvent: (_, event) {
                          if (event is KeyUpEvent || buckets.isEmpty) {
                            return KeyEventResult.ignored;
                          }
                          final direction =
                              event.logicalKey == LogicalKeyboardKey.arrowLeft
                              ? -1
                              : event.logicalKey ==
                                    LogicalKeyboardKey.arrowRight
                              ? 1
                              : 0;
                          if (direction == 0) return KeyEventResult.ignored;
                          setState(
                            () => selected = ((selected ?? 0) + direction)
                                .clamp(0, buckets.length - 1),
                          );
                          return KeyEventResult.handled;
                        },
                        child: Semantics(
                          label: detail,
                          child: MouseRegion(
                            onHover: (event) => select(event.localPosition.dx),
                            child: GestureDetector(
                              onTapDown: (event) =>
                                  select(event.localPosition.dx),
                              child: CustomPaint(
                                key: const ValueKey('traffic-line-chart'),
                                size: Size(width, plotHeight),
                                painter: _TrafficLines(
                                  buckets,
                                  maximum,
                                  up,
                                  down,
                                  theme.colorScheme.outlineVariant,
                                  showSend,
                                  showReceive,
                                  selected,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (buckets.isNotEmpty)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                buckets.first.shortLabel,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                buckets.last.shortLabel,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(detail, style: theme.textTheme.bodySmall),
        Text('空缺表示无记录；零流量显示为 0 B。', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _TrafficLines extends CustomPainter {
  _TrafficLines(
    this.buckets,
    this.maximum,
    this.up,
    this.down,
    this.grid,
    this.showSend,
    this.showReceive,
    this.selected,
  );
  final List<TrafficBucket> buckets;
  final double maximum;
  final Color up, down, grid;
  final bool showSend, showReceive;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final fraction in [0.0, .5, 1.0]) {
      canvas.drawLine(
        Offset(0, size.height * fraction),
        Offset(size.width, size.height * fraction),
        guide,
      );
    }
    double x(int i) => buckets.length < 2
        ? size.width / 2
        : i * size.width / (buckets.length - 1);
    void line(bool sending, Color color) {
      final path = Path();
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      var connected = false;
      for (var i = 0; i < buckets.length; i++) {
        final bucket = buckets[i];
        if (bucket.recordCount == 0) {
          connected = false;
          continue;
        }
        final y =
            size.height *
            (1 - (sending ? bucket.sentBytes : bucket.receivedBytes) / maximum);
        if (!connected) {
          path.moveTo(x(i), y);
        } else {
          path.lineTo(x(i), y);
        }
        // 单独一个有效区间也可见，零流量与缺失记录有明确区别。
        canvas.drawCircle(Offset(x(i), y), 1.5, Paint()..color = color);
        connected = true;
      }
      canvas.drawPath(path, paint);
    }

    if (showSend) line(true, up);
    if (showReceive) line(false, down);
    if (selected != null && selected! < buckets.length) {
      canvas.drawLine(
        Offset(x(selected!), 0),
        Offset(x(selected!), size.height),
        guide,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrafficLines old) =>
      buckets != old.buckets ||
      maximum != old.maximum ||
      up != old.up ||
      down != old.down ||
      grid != old.grid ||
      showSend != old.showSend ||
      showReceive != old.showReceive ||
      selected != old.selected;
}
