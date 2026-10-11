import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/services/runtime_preferences.dart';
import 'package:network_ui/services/native_bridge.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';
import 'package:network_ui/models/proxy_profile.dart';
import 'package:network_ui/services/proxy_controller.dart';

class TestDesktop extends NativeBridge {
  TestDesktop(this.directory);
  final Directory directory;
  final states = <bool>[];
  int windowShows = 0;
  @override
  Future<void> showWindow() async {
    windowShows++;
  }

  @override
  Future<Map<String, String>> environment() async => {
    'support': directory.path,
    'resources': directory.path,
  };
  @override
  Future<void> updateState({
    required bool running,
    required bool busy,
    required bool canApply,
  }) async {
    states.add(canApply);
  }
}

class TestKernel extends ProxyController {
  final writes = <(String, int?)>[];
  bool failWrite = false;
  int shutdownCalls = 0;
  Completer<void>? shutdownResult;
  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await shutdownResult?.future;
  }

  bool changeAfterApply = false;
  int starts = 0;
  final startedProfiles = <ProxyProfile>[];
  bool failStart = false;
  @override
  Future<int?> start(
    ProxyProfile profile,
    String resources, {
    bool applyDraft = true,
    int? expectedRevision,
  }) async {
    expect(applyDraft, isFalse);
    startedProfiles.add(profile);
    starts++;
    if (failStart) throw StateError('测试监听端口被占用');
    running = true;
    notifyListeners();
    return null;
  }

  void publish(ProxyProfile profile, int version) {
    connected = true;
    appliedProfile = profile;
    revision = configurationRevision = version;
    configurationChanged = false;
    notifyListeners();
  }

  @override
  Future<void> connect(
    ProxyProfile profile,
    String resources, {
    bool launch = true,
  }) async {}

  @override
  Future<int> apply(
    ProxyProfile profile,
    String resources, {
    int? expectedRevision,
  }) async {
    writes.add(('apply', expectedRevision));
    if (failWrite) throw StateError('测试数据库写入失败');
    final appliedRevision = revision + 1;
    publish(profile, appliedRevision);
    if (changeAfterApply) {
      publish(
        ProxyProfile(values: {'server.host': 'external.example'}),
        appliedRevision + 1,
      );
    }
    return appliedRevision;
  }

  @override
  Future<void> refreshConfiguration() async {
    configurationChanged = false;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('启动客户端时使用内核当前配置自动启动一次，不应用或保存草稿', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-auto-start-',
    );
    final kernel = TestKernel();
    kernel.publish(ProxyProfile(values: {'server.host': 'kernel.example'}), 1);
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory));
    try {
      await model.initialize();
      expect(kernel.running, isTrue);
      expect(kernel.starts, 1);
      expect(kernel.startedProfiles.single, same(kernel.appliedProfile));
      expect(kernel.writes, isEmpty);
      expect(model.dirty, isFalse);
      kernel.running = false;
      await model.initialize();
      await model.reload();
      expect(kernel.starts, 1);
      expect(kernel.running, isFalse);
    } finally {
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('已有运行中的代理直接接管，空配置不尝试启动', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-start-existing-',
    );
    for (final running in [true, false]) {
      final kernel = TestKernel()..running = running;
      kernel.publish(
        running
            ? ProxyProfile(values: {'server.host': 'kernel.example'})
            : ProxyProfile(connections: [], defaultConnectionId: ''),
        1,
      );
      final model = ProxyViewModel(
        proxy: kernel,
        native: TestDesktop(directory),
      );
      final messages = <UiMessage>[];
      final subscription = model.messages.stream.listen(messages.add);
      try {
        await model.initialize();
        expect(kernel.starts, 0);
        expect(kernel.running, running);
        expect(kernel.writes, isEmpty);
        expect(model.loading, isFalse);
        if (!running) expect(messages.single.text, contains('请先添加连接'));
      } finally {
        await subscription.cancel();
        model.dispose();
      }
    }
    await directory.delete(recursive: true);
  });

  test('自动启动失败明确提示，初始化完成后可以手动重试', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-start-failure-',
    );
    final kernel = TestKernel()..failStart = true;
    kernel.publish(ProxyProfile(values: {'server.host': 'kernel.example'}), 1);
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory));
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.initialize();
      expect(model.locked, isFalse);
      expect(kernel.running, isFalse);
      expect(messages.single.failure, isTrue);
      expect(messages.single.text, contains('自动启动代理失败'));
      kernel.failStart = false;
      await model.start();
      expect(kernel.starts, 2);
      expect(kernel.running, isTrue);
      expect(kernel.writes, isEmpty);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  });
  test('退出等待内核完成，重复请求合并且不修改草稿', () async {
    final kernel = TestKernel()..shutdownResult = Completer<void>();
    final desktop = TestDesktop(Directory.systemTemp);
    final model = ProxyViewModel(proxy: kernel, native: desktop)
      ..loading = false;
    try {
      model.dirty = true;
      final first = model.prepareToExit();
      final second = model.prepareToExit();
      expect(identical(first, second), isTrue);
      expect(kernel.shutdownCalls, 1);
      expect(model.locked, isTrue);
      var completed = false;
      unawaited(
        first.then((_) {
          completed = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      kernel.shutdownResult!.complete();
      expect(await first, isTrue);
      expect(model.locked, isFalse);
      expect(model.dirty, isTrue);
      expect(desktop.windowShows, 0);
    } finally {
      model.dispose();
    }
  });

  test('内核退出失败会显示窗口并取消退出，之后可以重试', () async {
    final kernel = TestKernel()..shutdownResult = Completer<void>();
    final desktop = TestDesktop(Directory.systemTemp);
    final model = ProxyViewModel(proxy: kernel, native: desktop)
      ..loading = false;
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      final result = model.prepareToExit();
      kernel.shutdownResult!.completeError(StateError('测试内核退出失败'));
      expect(await result, isFalse);
      expect(desktop.windowShows, 1);
      expect(messages.single.failure, isTrue);
      expect(messages.single.text, contains('已取消退出'));
      expect(model.locked, isFalse);
      kernel.shutdownResult = null;
      expect(await model.prepareToExit(), isTrue);
      expect(kernel.shutdownCalls, 2);
    } finally {
      await subscription.cancel();
      model.dispose();
    }
  });

  test('初始化或配置操作进行中取消退出，不并发停止内核', () async {
    final kernel = TestKernel();
    final desktop = TestDesktop(Directory.systemTemp);
    final model = ProxyViewModel(proxy: kernel, native: desktop);
    try {
      expect(await model.prepareToExit(), isFalse);
      model.loading = false;
      model.working = true;
      expect(await model.prepareToExit(), isFalse);
      model.working = false;
      kernel.busy = true;
      expect(await model.prepareToExit(), isFalse);
      expect(kernel.shutdownCalls, 0);
      expect(desktop.windowShows, 3);
    } finally {
      model.dispose();
    }
  });

  test('配置以内核为准，普通状态不丢草稿，应用后保存同一版本', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-kernel-source-',
    );
    final kernel = TestKernel();
    kernel.publish(ProxyProfile(values: {'server.host': 'kernel.example'}), 1);
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory));
    try {
      await model.initialize();
      expect(model.fields['server.host']!.text, 'kernel.example');
      model.fields['server.host']!.text = 'draft.example';
      model.changed('');
      kernel.notifyListeners();
      expect(model.fields['server.host']!.text, 'draft.example');
      expect(model.dirty, isTrue);
      kernel.publish(
        ProxyProfile(values: {'server.host': 'kernel.example'}),
        1,
      );
      expect(model.fields['server.host']!.text, 'draft.example');
      expect(model.dirty, isTrue);
      kernel.publish(
        ProxyProfile(values: {'server.host': 'latest.example'}),
        2,
      );
      expect(model.fields['server.host']!.text, 'latest.example');
      expect(model.baseRevision, 2);
      expect(model.dirty, isFalse);
      model.fields['server.host']!.text = 'applied.example';
      model.changed('');
      await model.apply();
      expect(kernel.writes, [('apply', 2)]);
      expect(model.baseRevision, 3);
      expect(model.fields['server.host']!.text, 'applied.example');
      model.fields['server.host']!.text = 'restart-draft.example';
      model.changed('');
      kernel.kernelGeneration++;
      kernel.publish(
        ProxyProfile(values: {'server.host': 'restarted.example'}),
        3,
      );
      expect(model.fields['server.host']!.text, 'restarted.example');
      expect(model.dirty, isFalse);
    } finally {
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('事务写入失败保留草稿与原配置，不报告保存成功', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-save-failure-',
    );
    final kernel = TestKernel()..failWrite = true;
    kernel.publish(ProxyProfile(values: {'server.host': 'kernel.example'}), 1);
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory));
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.initialize();
      model.fields['server.host']!.text = 'applied.example';
      model.changed('');
      await model.apply();
      expect(kernel.writes, [('apply', 1)]);
      expect(model.dirty, isTrue);
      expect(model.fields['server.host']!.text, 'applied.example');
      expect(messages.last.failure, isTrue);
      expect(messages.last.text, contains('测试数据库写入失败'));
      expect(messages.any((message) => message.text == '配置已应用并保存到内核'), isFalse);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('应用成功后同步外部修改，不追加二次保存请求', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-save-race-',
    );
    final kernel = TestKernel()..changeAfterApply = true;
    kernel.publish(ProxyProfile(values: {'server.host': 'kernel.example'}), 1);
    final model = ProxyViewModel(proxy: kernel, native: TestDesktop(directory));
    final messages = <UiMessage>[];
    final subscription = model.messages.stream.listen(messages.add);
    try {
      await model.initialize();
      model.fields['server.host']!.text = 'applied.example';
      model.changed('');
      await model.apply();
      expect(kernel.writes, [('apply', 1)]);
      expect(kernel.revision, 3);
      expect(model.fields['server.host']!.text, 'external.example');
      expect(model.baseRevision, 3);
      expect(messages.last.failure, isFalse);
      expect(messages.any((message) => message.text == '配置已应用并保存到内核'), isTrue);
    } finally {
      await subscription.cancel();
      model.dispose();
      await directory.delete(recursive: true);
    }
  });
  test('视图模型保留多连接草稿，状态变化同步菜单，日志不刷新整个界面', () async {
    final directory = await Directory.systemTemp.createTemp('network-model-');
    final desktop = TestDesktop(directory);
    final model = ProxyViewModel(native: desktop);
    try {
      await model.initialize();
      model.navigate(1);
      expect(desktop.states.last, isTrue);
      model.fields['server.host']!.text = 'first.example';
      model.fields['password']!.text = 'test-only';
      model.changed('');
      final first = model.editingId;
      model.addConnection();
      model.fields['server.host']!.text = 'second.example';
      model.changed('');
      model.editConnection(first);
      expect(model.fields['server.host']!.text, 'first.example');
      expect(model.fields['password']!.text, 'test-only');
      expect(model.draftProfile().connections.length, 2);
      model.navigate(0);
      expect(desktop.states.last, isFalse);
      var rebuilds = 0;
      var logUpdates = 0;
      model.addListener(() => rebuilds++);
      model.proxy.logChanges.addListener(() => logUpdates++);
      model.proxy.addLog('INFO 测试日志');
      expect(rebuilds, 0);
      expect(logUpdates, 1);
    } finally {
      model.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('启动路径存储可独立读写且不保存代理凭据', () async {
    final directory = await Directory.systemTemp.createTemp(
      'network-preferences-',
    );
    final preferences = RuntimePreferences();
    try {
      expect((await preferences.read(directory)).jarPath, isEmpty);
      await preferences.write(
        directory,
        const RuntimePaths('/runtime/java', '/kernel/client.jar'),
      );
      final loaded = await preferences.read(directory);
      expect(loaded.javaPath, '/runtime/java');
      expect(loaded.jarPath, '/kernel/client.jar');
      expect(await File('${directory.path}/ui.json.tmp').exists(), isFalse);
      expect(await directory.list().length, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
