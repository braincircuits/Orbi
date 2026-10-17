import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

/// 独立 Profile 入口，仅使用模拟数据和未完成的查询，不读写用户配置。
void main() => runApp(const _Benchmark());

class _Profile extends ProxyProfile {
  int targetReads = 0;
  @override
  Map<String, String> get targetRoutes {
    targetReads++;
    return super.targetRoutes;
  }
}

class _Kernel extends ProxyController {
  final pending = Completer<AccessRecordPage>();
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) => pending.future;
}

class _Desktop extends NativeBridge {
  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {}
}

class _Model extends ProxyViewModel {
  _Model(_Kernel kernel) : super(proxy: kernel, native: _Desktop()) {
    loading = false;
    page = 4;
    accept(kernel.appliedProfile!);
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<void> refreshOverview() async {}
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final profile = _Profile();
  late final kernel = _Kernel()
    ..connected = true
    ..appliedProfile = profile;
  late final model = _Model(kernel);
  final root = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _select(bool history) {
    Element? page;
    SegmentedButton<bool>? button;
    void findPage(Element element) {
      if (element.widget is TunnelsPage) page = element;
      element.visitChildren(findPage);
    }

    void findButton(Element element) {
      if (element.widget is SegmentedButton<bool>) {
        button = element.widget as SegmentedButton<bool>;
      }
      element.visitChildren(findButton);
    }

    root.currentContext!.visitChildElements(findPage);
    page!.visitChildren(findButton);
    button!.onSelectionChanged!({history});
  }

  Future<void> _idle(String state) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    var frames = 0;
    var micros = 0;
    void record(List<FrameTiming> timings) {
      frames += timings.length;
      micros += timings.fold(
        0,
        (sum, frame) => sum + frame.buildDuration.inMicroseconds,
      );
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    SchedulerBinding.instance.removeTimingsCallback(record);
    stdout.writeln(
      '隐藏页空闲测量：${jsonEncode({'状态': state, '采集毫秒': 800, '帧数': frames, '累计帧构建微秒': micros})}',
    );
  }

  Future<void> _measure() async {
    _select(true);
    await _idle('访问记录可见且查询未完成');
    _select(false);
    await _idle('访问记录隐藏，实时隧道可见');
    _select(true);
    model.navigate(1);
    await _idle('访问记录保留，连接配置可见');
    kernel.pending.complete(
      AccessRecordPage.fromJson({
        'items': <Map<String, dynamic>>[],
        'hasMore': false,
        'nextValue': 0,
        'nextHost': '',
      }),
    );
    profile.rules = List.generate(
      5000,
      (i) => 'rule-$i.example # 测试备注',
    ).join('\n');
    profile.routesOverrides = List.generate(
      5000,
      (i) => 'proxy target-$i.example',
    ).join('\n');
    model.accept(profile);
    model.update(() {});
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final timings = <int>[];
    void record(List<FrameTiming> frames) {
      timings.addAll(frames.map((frame) => frame.buildDuration.inMicroseconds));
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    profile.targetReads = 0;
    for (var i = 0; i < 30; i++) {
      model.update(() {});
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    SchedulerBinding.instance.removeTimingsCallback(record);
    if (timings.isEmpty) throw StateError('未采集到页面刷新帧');
    timings.sort();
    stdout.writeln(
      '规则页无关刷新测量：${jsonEncode({'直连规则数': 5000, '指定目标数': 5000, '刷新次数': 30, '目标规则解析次数': profile.targetReads, '帧构建中位数微秒': timings[timings.length ~/ 2], '帧构建最大微秒': timings.last})}',
    );
    await stdout.flush();
    exit(0);
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: root,
    child: NetworkApp(model: model),
  );
}
