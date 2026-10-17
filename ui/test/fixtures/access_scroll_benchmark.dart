import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/sortable_table.dart';

/// 独立 Profile 入口，仅使用模拟记录，不读取用户配置或启动代理。
void main() => runApp(const _Benchmark());

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final scroll = ScrollController(keepScrollOffset: false);
  bool fixed = false;
  int rowsBuilt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  Future<void> _measure() async {
    for (final mode in [false, true]) {
      setState(() => fixed = mode);
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      rowsBuilt = 0;
      final samples = <int>[];
      for (final end in [true, false, true]) {
        final watch = Stopwatch()..start();
        scroll.jumpTo(end ? scroll.position.maxScrollExtent : 0);
        await SchedulerBinding.instance.endOfFrame;
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      samples.sort();
      stdout.writeln(
        '滚动性能测量：${jsonEncode({'模式': mode ? '固定行高' : '逐行测量', '记录数': 5000, '跳跃次数': 3, '构建行数': rowsBuilt, '布局等待中位数微秒': samples[1], '布局等待最大微秒': samples.last})}',
      );
    }
    await stdout.flush();
    exit(0);
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: desktopTheme(Brightness.light),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SortableTable(
          key: ValueKey(fixed),
          columns: const ['域名 / IP', '连接次数', '最后访问时间', '最后失败时间'],
          widths: const [280, 120, 210, 210],
          sortColumn: 2,
          ascending: false,
          onSort: null,
          controller: scroll,
          rowCount: 5000,
          rowKey: (index) => 'record-$index.example',
          itemExtent: fixed ? 48 : null,
          empty: const SizedBox(),
          cells: (index) {
            rowsBuilt++;
            return [
              TableText('record-$index.example'),
              TableText('${index + 1}'),
              const TableText('2026-10-17 12:00:00'),
              const TableText('—'),
            ];
          },
        ),
      ),
    ),
  );
}
