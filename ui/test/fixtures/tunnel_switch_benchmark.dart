import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

/// 独立 Profile 入口，只使用模拟数据，不连接内核或读取用户配置。
void main() => runApp(const _Benchmark());

class _RowProbe {
  int built = 0;
}

class _Tunnel extends TunnelStatus {
  _Tunnel(int index, this.probe)
    : super(
        id: '$index',
        target: 'record-$index.example:443',
        source: '127.0.0.1:12345',
        route: 'direct',
        state: 'active',
        profileName: '',
        protocol: 'tcp',
        originalProtocol: 'tcp',
        createdAt: DateTime(2026, 10, 17).add(Duration(seconds: index)),
      );
  final _RowProbe probe;

  @override
  String get protocolLabel {
    probe.built++;
    return super.protocolLabel;
  }
}

class _Kernel extends ProxyController {
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) async => AccessRecordPage.fromJson({
    'items': List.generate(
      5000,
      (i) => {
        'host': 'history-$i.example',
        'connectionCount': i + 1,
        'lastAccessAt': 1792238400000,
        'lastFailureAt': 0,
      },
    ),
    'hasMore': false,
    'nextValue': 0,
    'nextHost': '',
  });
}

class _Desktop extends NativeBridge {
  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final root = GlobalKey();
  final probe = _RowProbe();
  late final kernel = _Kernel()
    ..connected = true
    ..tunnels = List.generate(5000, (i) => _Tunnel(i, probe));
  late final model = ProxyViewModel(proxy: kernel, native: _Desktop())
    ..loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  T _find<T extends Widget>() {
    T? result;
    void visit(Element element) {
      if (result != null) return;
      if (element.widget is T) result = element.widget as T;
      element.visitChildren(visit);
    }

    root.currentContext!.visitChildElements(visit);
    return result!;
  }

  Future<void> _select(bool history) async {
    _find<SegmentedButton<bool>>().onSelectionChanged!({history});
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> _measure() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final timings = <int>[];
    void record(List<FrameTiming> frames) {
      timings.addAll(frames.map((frame) => frame.buildDuration.inMicroseconds));
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    for (final offset in [0.0, 200000.0]) {
      _find<ListView>().controller!.jumpTo(offset);
      await SchedulerBinding.instance.endOfFrame;
      final samples = <int>[];
      final builds = <int>[];
      var built = 0;
      for (var i = 0; i < 3; i++) {
        await _select(true);
        probe.built = 0;
        timings.clear();
        final watch = Stopwatch()..start();
        _find<SegmentedButton<bool>>().onSelectionChanged!({false});
        await SchedulerBinding.instance.endOfFrame;
        watch.stop();
        samples.add(watch.elapsedMicroseconds);
        built += probe.built;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (timings.isEmpty) throw StateError('未采集到切换帧耗时');
        timings.sort();
        builds.add(timings.last);
      }
      samples.sort();
      builds.sort();
      stdout.writeln(
        '页签切换性能：${jsonEncode({'隧道数': 5000, '访问记录数': 5000, '隧道滚动位置': offset, '切换次数': 3, '构建行数': built, '首帧等待中位数微秒': samples[1], '首帧等待最大微秒': samples.last, '帧构建中位数微秒': builds[1]})}',
      );
    }
    SchedulerBinding.instance.removeTimingsCallback(record);
    await stdout.flush();
    exit(0);
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: desktopTheme(Brightness.light),
    home: Scaffold(
      key: root,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: TunnelsPage(model: model),
      ),
    ),
  );
}
