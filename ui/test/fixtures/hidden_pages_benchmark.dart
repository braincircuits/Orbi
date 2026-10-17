import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:network_ui/main.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/services/proxy_controller.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

/// 独立 Profile 入口，使用模拟推送，不读取配置或连接真实内核。
void main() => runApp(const _Benchmark());

class _Kernel extends ProxyController {
  int logReads = 0;
  @override
  List<KernelLog> get logs {
    logReads++;
    return super.logs;
  }

  void publish() => notifyListeners();
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
    page = 1;
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
  final kernel = _Kernel();
  late final model = _Model(kernel);
  @override
  void initState() {
    super.initState();
    kernel.tunnels = List.generate(5000, (i) => _tunnel(i, 0));
    for (var i = 0; i < 500; i++) {
      kernel.addLog('INFO 模拟请求 $i');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  TunnelStatus _tunnel(int i, int sample) => TunnelStatus(
    id: '$i',
    target: 'record-$i.example:443',
    source: '127.0.0.1:12345',
    route: 'direct',
    state: 'active',
    profileName: '',
    protocol: 'tcp',
    originalProtocol: 'tcp',
    createdAt: DateTime(2026, 10, 17).add(Duration(seconds: sample)),
  );
  Future<void> _measure() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final timings = <int>[];
    void record(List<FrameTiming> frames) {
      timings.addAll(frames.map((frame) => frame.buildDuration.inMicroseconds));
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    kernel.logReads = 0;
    for (var i = 1; i <= 50; i++) {
      kernel.tunnels = [...kernel.tunnels]..[0] = _tunnel(0, i);
      kernel.publish();
      kernel.addLog('INFO 模拟新请求 $i');
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    SchedulerBinding.instance.removeTimingsCallback(record);
    timings.sort();
    stdout.writeln(
      '后台页面性能测量：${jsonEncode({'隧道数': 5000, '日志数': 500, '推送次数': 50, '日志列表读取次数': kernel.logReads, '帧数': timings.length, '帧构建中位数微秒': timings[timings.length ~/ 2], '帧构建最大微秒': timings.last})}',
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
  Widget build(BuildContext context) => NetworkApp(model: model);
}
