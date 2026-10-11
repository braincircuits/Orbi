import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/kernel_status.dart';
import '../desktop_theme.dart';

/// 流量统一使用十进制单位，速率与坐标轴使用同一换算口径。
String formatTrafficBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 || value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2)} ${units[unit]}';
}

/// 仅展示内核采样，不生成流量；时间范围和曲线显隐保存在页面状态中。
class TrafficChart extends StatefulWidget {
  const TrafficChart({
    super.key,
    required this.traffic,
    required this.connected,
    required this.running,
  });
  final TrafficSnapshot? traffic;
  final bool connected, running;
  @override
  State<TrafficChart> createState() => _TrafficChartState();
}

class _TrafficChartState extends State<TrafficChart> {
  int minutes = 1;
  bool showSend = true, showReceive = true;
  double? pointer;
  @override
  void didUpdateWidget(TrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.traffic?.sessionId != widget.traffic?.sessionId ||
        !widget.connected) {
      pointer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.traffic?.current;
    final end = current?.sampledAt ?? 0;
    final start = end - minutes * 60000;
    final samples =
        widget.traffic?.history
            .where((sample) => sample.sampledAt >= start)
            .toList() ??
        <TrafficSample>[];
    final sendColor = DesktopDesign.trafficSend(theme.brightness);
    final receiveColor = DesktopDesign.trafficReceive(theme.brightness);
    final available = widget.connected && samples.isNotEmpty;
    Widget legend(
      String label,
      Color color,
      bool selected,
      VoidCallback toggle,
    ) => TextButton.icon(
      onPressed: toggle,
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
      ),
      icon: Icon(
        selected ? Icons.show_chart : Icons.visibility_off_outlined,
        size: 16,
        color: selected ? color : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(label),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('流量趋势', style: theme.textTheme.titleMedium)),
            SegmentedButton<int>(
              key: const ValueKey('traffic-range'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1 分钟')),
                ButtonSegment(value: 5, label: Text('5 分钟')),
              ],
              selected: {minutes},
              onSelectionChanged: (value) => setState(() {
                minutes = value.single;
                pointer = null;
              }),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              toggled: showSend,
              child: legend(
                '发送',
                sendColor,
                showSend,
                () => setState(() {
                  showSend = !showSend;
                  pointer = null;
                }),
              ),
            ),
            Semantics(
              toggled: showReceive,
              child: legend(
                '接收',
                receiveColor,
                showReceive,
                () => setState(() {
                  showReceive = !showReceive;
                  pointer = null;
                }),
              ),
            ),
            Text('全部接入流量 · 代理与直连', style: theme.textTheme.bodySmall),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final geometry = _TrafficGeometry(samples, start, end, width);
            final selected = pointer == null || !available
                ? null
                : geometry.read(pointer!);
            return MouseRegion(
              onHover: (event) =>
                  setState(() => pointer = event.localPosition.dx),
              onExit: (_) => setState(() => pointer = null),
              child: GestureDetector(
                onTapDown: (event) =>
                    setState(() => pointer = event.localPosition.dx),
                child: Semantics(
                  label:
                      '最近 $minutes 分钟流量趋势，${widget.connected && current != null ? '发送 ${formatTrafficBytes(widget.running ? current.sendBytesPerSecond : 0)} 每秒，接收 ${formatTrafficBytes(widget.running ? current.receiveBytesPerSecond : 0)} 每秒' : '内核未连接'}',
                  child: SizedBox(
                    height: 180,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            key: const ValueKey('traffic-plot'),
                            painter: _TrafficPainter(
                              geometry: geometry,
                              sendColor: sendColor,
                              receiveColor: receiveColor,
                              lineColor: theme.colorScheme.outlineVariant,
                              textStyle: theme.textTheme.bodySmall!,
                              showSend: showSend && available,
                              showReceive: showReceive && available,
                              pointer: selected == null ? null : pointer,
                              faded: !widget.running,
                            ),
                          ),
                        ),
                        if (!available || !showSend && !showReceive)
                          Center(
                            child: Text(
                              !widget.connected
                                  ? '内核未连接，流量数据不可用'
                                  : samples.isEmpty
                                  ? '开启服务后开始记录流量'
                                  : '选择发送或接收以显示曲线',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        if (selected != null && (showSend || showReceive))
                          Positioned(
                            left: (pointer! + 12).clamp(
                              0,
                              math.max(0, width - 178),
                            ),
                            top: 24,
                            child: IgnorePointer(
                              child: Container(
                                width: math.min(178, width),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color:
                                      theme.colorScheme.surfaceContainerLowest,
                                  border: Border.all(
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      DateTime.fromMillisecondsSinceEpoch(
                                        selected.$1,
                                      ).toString().split('.').first,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    if (showSend)
                                      Text(
                                        '发送 ${formatTrafficBytes(selected.$2)}/s',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    if (showReceive)
                                      Text(
                                        '接收 ${formatTrafficBytes(selected.$3)}/s',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('累计值自本次启动起计算', style: theme.textTheme.bodySmall),
            Text(
              !widget.connected
                  ? '等待内核连接'
                  : widget.running
                  ? '每秒采样'
                  : '服务已停止 · 保留最近记录',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _TrafficGeometry {
  _TrafficGeometry(this.samples, this.start, this.end, this.width);
  final List<TrafficSample> samples;
  final int start, end;
  final double width;
  static const left = 48.0, top = 22.0, bottom = 150.0;
  double get right => math.max(left + 1, width - 8);
  double get maximum =>
      samples.fold(
        1000.0,
        (value, sample) => math.max(
          value,
          math.max(sample.sendBytesPerSecond, sample.receiveBytesPerSecond),
        ),
      ) *
      1.15;
  double x(int time) => left + (time - start) / (end - start) * (right - left);
  double y(double value) => bottom - value / maximum * (bottom - top);
  (int, double, double)? read(double pointer) {
    final time =
        (start +
                ((pointer - left) / (right - left)).clamp(0, 1) * (end - start))
            .round();
    for (var i = 1; i < samples.length; i++) {
      final a = samples[i - 1], b = samples[i];
      if (time >= a.sampledAt &&
          time <= b.sampledAt &&
          b.sampledAt - a.sampledAt <= 2500) {
        final ratio = (time - a.sampledAt) / (b.sampledAt - a.sampledAt);
        return (
          time,
          a.sendBytesPerSecond +
              (b.sendBytesPerSecond - a.sendBytesPerSecond) * ratio,
          a.receiveBytesPerSecond +
              (b.receiveBytesPerSecond - a.receiveBytesPerSecond) * ratio,
        );
      }
    }
    return null;
  }
}

class _TrafficPainter extends CustomPainter {
  _TrafficPainter({
    required this.geometry,
    required this.sendColor,
    required this.receiveColor,
    required this.lineColor,
    required this.textStyle,
    required this.showSend,
    required this.showReceive,
    required this.pointer,
    required this.faded,
  });
  final _TrafficGeometry geometry;
  final Color sendColor, receiveColor, lineColor;
  final TextStyle textStyle;
  final bool showSend, showReceive, faded;
  final double? pointer;

  void label(
    Canvas canvas,
    String value,
    double x,
    double y, {
    double alignment = 0,
  }) {
    final text = TextPainter(
      text: TextSpan(text: value, style: textStyle.copyWith(fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(x - text.width * alignment, y));
    text.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final unit = g.maximum >= 1000000 ? 1000000.0 : 1000.0;
    label(canvas, unit == 1000000 ? 'MB/s' : 'KB/s', 0, 0);
    final grid = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final value = g.maximum * i / 3, y = g.y(value);
      canvas.drawLine(
        Offset(_TrafficGeometry.left, y),
        Offset(g.right, y),
        grid,
      );
      label(
        canvas,
        (value / unit).toStringAsFixed(value == 0 ? 0 : 1),
        _TrafficGeometry.left - 8,
        y - 7,
        alignment: 1,
      );
    }
    final ticks = size.width < 380 ? 2 : 4;
    for (var i = 0; i <= ticks; i++) {
      final seconds = ((g.end - g.start) / 1000 * (1 - i / ticks)).round();
      final text = seconds == 0
          ? '现在'
          : seconds >= 60
          ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} 前'
          : '$seconds 秒前';
      label(
        canvas,
        text,
        _TrafficGeometry.left + (g.right - _TrafficGeometry.left) * i / ticks,
        159,
        alignment: i == 0
            ? 0
            : i == ticks
            ? 1
            : .5,
      );
    }
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        _TrafficGeometry.left - 2,
        _TrafficGeometry.top,
        g.right + 2,
        _TrafficGeometry.bottom + 2,
      ),
    );
    void line(bool sending, Color color) {
      final path = Path();
      TrafficSample? previous;
      for (final sample in g.samples) {
        final x = g.x(sample.sampledAt),
            y = g.y(
              sending
                  ? sample.sendBytesPerSecond
                  : sample.receiveBytesPerSecond,
            );
        if (previous == null || sample.sampledAt - previous.sampledAt > 2500) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        previous = sample;
      }
      final paint = Paint()
        ..color = color.withValues(alpha: faded ? .4 : 1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, paint);
    }

    if (showSend) line(true, sendColor);
    if (showReceive) line(false, receiveColor);
    if (pointer != null) {
      final point = g.read(pointer!);
      if (point != null) {
        final x = g.x(point.$1);
        canvas.drawLine(
          Offset(x, _TrafficGeometry.top),
          Offset(x, _TrafficGeometry.bottom),
          grid,
        );
        if (showSend) {
          canvas.drawCircle(
            Offset(x, g.y(point.$2)),
            3,
            Paint()..color = sendColor,
          );
        }
        if (showReceive) {
          canvas.drawCircle(
            Offset(x, g.y(point.$3)),
            3,
            Paint()..color = receiveColor,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TrafficPainter oldDelegate) => true;
}
