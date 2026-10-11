import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/proxy_profile.dart';
import '../services/native_bridge.dart';
import '../services/kernel_api_client.dart';
import '../services/proxy_controller.dart';
import '../services/runtime_preferences.dart';
import '../services/appearance_preferences.dart';

class UiMessage {
  const UiMessage(this.text, {this.failure = false});
  final String text;
  final bool failure;
}

/// 保存编辑草稿并协调内核操作；页面只负责展示与用户交互。
class ProxyViewModel extends ChangeNotifier {
  ProxyViewModel({
    ProxyController? proxy,
    NativeBridge? native,
    RuntimePreferences? preferences,
    AppearancePreferences? appearancePreferences,
  }) : proxy = proxy ?? ProxyController(),
       native = native ?? NativeBridge(),
       preferences = preferences ?? RuntimePreferences(),
       appearancePreferences =
           appearancePreferences ?? AppearancePreferences() {
    for (final e in ProxyProfile.defaults.entries) {
      fields[e.key] = TextEditingController(text: e.value);
    }
    logScroll.addListener(_logPositionChanged);
    this.proxy.addListener(_proxyChanged);
    this.proxy.logChanges.addListener(_logsChanged);
  }
  String _tunTicket = '';
  bool? tunServiceInstalled;
  bool checkingTunService = false;
  String tunServiceError = '';
  bool get supportsTunService => Platform.isMacOS;
  final NativeBridge native;
  final ProxyController proxy;
  final RuntimePreferences preferences;
  final AppearancePreferences appearancePreferences;
  final themeMode = ValueNotifier(ThemeMode.system);
  bool savingAppearance = false;
  final messages = StreamController<UiMessage>.broadcast(sync: true);
  bool _disposed = false;
  bool _initialized = false;
  Future<bool>? _exitRequest;
  bool get active => !_disposed;
  void update(VoidCallback action) {
    if (_disposed) return;
    action();
    notifyListeners();
    _syncDesktop();
  }

  void _logPositionChanged() {
    if (!logScroll.hasClients || _disposed) return;
    final next = logScroll.position.extentAfter < 40;
    if (followLogs != next) update(() => followLogs = next);
  }

  final fields = <String, TextEditingController>{};
  final rules = TextEditingController();
  final routesFile = TextEditingController();
  final target = TextEditingController(text: 'www.google.com:443');
  bool inlineRules = true;
  bool followLogs = true;
  bool working = false;
  String? testProfileId;
  int? baseRevision;
  ProxyProfile? _acceptedKernelProfile;
  int _acceptedKernelGeneration = 0;
  final java = TextEditingController();
  final jar = TextEditingController();
  final logScroll = ScrollController();
  String resources = '';
  bool sidebarMaterial = false;
  bool get usesNativeKernel => nativeKernelExecutable(resources).isNotEmpty;
  int page = 0;
  bool loading = true, dirty = false, showPassword = false, pauseLogs = false;
  String filter = '全部';
  final connectionName = TextEditingController();
  List<ConnectionProfile> connectionDrafts = [
    ConnectionProfile(id: 'default', name: '默认连接'),
  ];
  String editingId = 'default';
  String defaultId = 'default';
  ConnectionProfile get editingConnection =>
      connectionDrafts.firstWhere((c) => c.id == editingId);
  ConnectionProfile? get activeConnection => proxy.appliedProfile?.connections
      .where((c) => c.id == proxy.defaultConnectionId)
      .firstOrNull;
  ConnectionProfile? get draftConnection =>
      connectionDrafts.where((c) => c.id == defaultId).firstOrNull;

  void captureConnection() {
    if (connectionDrafts.isEmpty) return;
    final current = editingConnection;
    current.name = connectionName.text.trim();
    for (final key in ProxyProfile.defaults.keys) {
      if (!ProxyProfile.localKeys.contains(key)) {
        current.values[key] = key == 'password'
            ? fields[key]!.text
            : fields[key]!.text.trim();
      }
    }
  }

  void showConnection(ConnectionProfile connection) {
    showPassword = false;
    editingId = connection.id;
    connectionName.text = connection.name;
    for (final key in ProxyProfile.defaults.keys) {
      if (!ProxyProfile.localKeys.contains(key)) {
        fields[key]!.text = connection.values[key]!;
      }
    }
  }

  void editConnection(String id) {
    captureConnection();
    update(() {
      showConnection(connectionDrafts.firstWhere((c) => c.id == id));
    });
  }

  void addConnection() {
    captureConnection();
    final connection = ConnectionProfile(
      id: 'node-${DateTime.now().microsecondsSinceEpoch}',
      name: '新连接 ${connectionDrafts.length + 1}',
    );
    update(() {
      if (connectionDrafts.isEmpty) defaultId = connection.id;
      connectionDrafts.add(connection);
      showConnection(connection);
    });
    changed('');
  }

  void removeConnection() {
    if (editingId == proxy.defaultConnectionId ||
        editingId == defaultId &&
            (connectionDrafts.length > 1 || proxy.running)) {
      return;
    }
    update(() {
      connectionDrafts.removeWhere((c) => c.id == editingId);
      if (connectionDrafts.isEmpty) {
        defaultId = editingId = '';
      } else {
        showConnection(connectionDrafts.firstWhere((c) => c.id == defaultId));
      }
    });
    changed('');
  }

  void accept(ProxyProfile profile) {
    _acceptedKernelProfile = profile;
    _acceptedKernelGeneration = proxy.kernelGeneration;
    final previousEditingId = editingId;
    for (final e in profile.values.entries) {
      fields[e.key]?.text = e.value;
    }
    connectionDrafts = profile.connections.map((c) => c.copy()).toList();
    defaultId = profile.defaultConnectionId;
    if (connectionDrafts.isNotEmpty) {
      showConnection(
        connectionDrafts.where((c) => c.id == previousEditingId).firstOrNull ??
            profile.selected,
      );
    } else {
      editingId = '';
    }
    rules.text = profile.rules;
    routesFile.text = profile.routesFile;
    inlineRules = profile.inlineRules;
    baseRevision = proxy.configurationRevision;
    dirty = false;
  }

  Future<void> ensureKernel() async {
    await proxy.connect(draftProfile(), resources);
    final profile = proxy.appliedProfile!;
    if (!identical(profile, _acceptedKernelProfile)) {
      if (baseRevision == null && profile.connections.isNotEmpty ||
          baseRevision != null &&
              (baseRevision != proxy.configurationRevision ||
                  _acceptedKernelGeneration != proxy.kernelGeneration)) {
        update(() => accept(profile));
        throw StateError('已同步内核配置，请核对后重新操作');
      }
      // 首次启动空内核时，保留用户刚填写的配置用于首次提交。
      _acceptedKernelProfile = profile;
      _acceptedKernelGeneration = proxy.kernelGeneration;
      baseRevision = proxy.configurationRevision;
    }
  }

  Future<void> reload() async {
    await action(() async {
      await proxy.connect(draftProfile(), resources);
      await proxy.refreshConfiguration();
      if (active) update(() => accept(proxy.appliedProfile!));
    });
  }

  Future<void> action(Future<void> Function() action) async {
    if (working || !active) return;
    update(() => working = true);
    _syncDesktop();
    try {
      await action();
    } catch (e) {
      if (proxy.configurationChanged ||
          e is KernelApiException &&
              (e.code == 'REVISION_CONFLICT' || e.code == 'KERNEL_RESTARTED')) {
        try {
          await proxy.refreshConfiguration();
          if (active) update(() => accept(proxy.appliedProfile!));
          message('已同步内核最新配置，请核对后重新操作', failure: true);
        } catch (syncError) {
          message(
            '同步内核配置失败：${proxy.redact(syncError.toString())}',
            failure: true,
          );
        }
      }
      message(
        proxy.redact(e.toString().replaceFirst('Bad state: ', '')),
        failure: true,
      );
    } finally {
      if (active) {
        update(() {
          working = false;
          _acceptKernelConfiguration();
        });
        _syncDesktop();
      }
    }
  }

  Future<void> apply() => action(() async {
    final profile = draftProfile();
    await ensureKernel();
    await proxy.apply(profile, resources, expectedRevision: baseRevision);
    if (active) update(() => accept(proxy.appliedProfile!));
    message('配置已应用并保存到内核');
  });

  Future<void> switchConnection(String id) => action(() async {
    if (id == proxy.defaultConnectionId) return;
    if (!proxy.connected) throw StateError('请先连接代理内核');
    if (!proxy.appliedProfile!.connections.any((c) => c.id == id)) {
      throw StateError('此连接尚未应用，请先应用配置后再使用');
    }
    captureConnection();
    final keepDraft = dirty;
    final appliedRevision = await proxy.selectConnection(
      id,
      expectedRevision: baseRevision,
    );
    if (active) {
      update(() {
        // 只合并本次切换的默认连接与版本，保留表单、规则和密码草稿。
        // 若发生其他配置写入，继续按现有冲突处理同步内核快照。
        if (keepDraft &&
            proxy.configurationRevision == appliedRevision &&
            _acceptedKernelGeneration == proxy.kernelGeneration) {
          _acceptedKernelProfile = proxy.appliedProfile;
          baseRevision = appliedRevision;
          defaultId = id;
        } else {
          accept(proxy.appliedProfile!);
        }
      });
    }
    message('默认连接已切换并保存，旧代理隧道已关闭${keepDraft ? '；编辑草稿已保留' : ''}');
  });

  Future<void> setRoutingMode(String mode) => action(() async {
    if (mode == proxy.routingMode) return;
    if (!proxy.connected) throw StateError('请先连接代理内核');
    captureConnection();
    final keepDraft = dirty;
    final appliedRevision = await proxy.setRoutingMode(
      mode,
      expectedRevision: baseRevision,
    );
    if (active) {
      update(() {
        // 只合并全局模式及版本，不提交尚未应用的编辑草稿。
        if (keepDraft &&
            proxy.configurationRevision == appliedRevision &&
            _acceptedKernelGeneration == proxy.kernelGeneration) {
          _acceptedKernelProfile = proxy.appliedProfile;
          baseRevision = appliedRevision;
        } else {
          accept(proxy.appliedProfile!);
        }
      });
    }
    // 成功由模式选中态直接反馈，避免连续切换时成功提示排队播放。
  });

  Future<void> startOverview(String kind) =>
      action(() => proxy.startOverview(kind));

  /// 初次进入概览或连接状态变化后更新，已有同类检测继续使用。
  Future<void> refreshOverview() async {
    for (final kind in ['latency', 'exit-ip']) {
      if (!active || locked || !proxy.connected || !proxy.running) return;
      if (kind == 'latency' && proxy.routingMode == 'direct') continue;
      try {
        await proxy.startOverview(kind);
      } catch (_) {
        // 请求失败由控制器状态显示；自动刷新不追加弹窗。
      }
    }
  }

  void discardDrafts() {
    if (locked || _acceptedKernelProfile == null) return;
    update(() => accept(_acceptedKernelProfile!));
  }

  Future<void> routeTarget(String target, String route) => action(() async {
    if (!proxy.connected) throw StateError('请先连接代理内核');
    captureConnection();
    final keepDraft = dirty;
    final appliedRevision = await proxy.routeTarget(
      target,
      route,
      expectedRevision: baseRevision,
    );
    if (active) {
      update(() {
        // 只合并本次目标路由和版本，保留连接、默认连接、规则及密码草稿。
        if (keepDraft &&
            proxy.configurationRevision == appliedRevision &&
            _acceptedKernelGeneration == proxy.kernelGeneration) {
          _acceptedKernelProfile = proxy.appliedProfile;
          baseRevision = appliedRevision;
        } else {
          accept(proxy.appliedProfile!);
        }
      });
    }
    message(
      '${route == 'auto' ? '已恢复自动路由' : '目标已切换为${route == 'direct' ? '直连' : '代理'}'}并保存；路由变化的连接已断开，请求重连后生效${keepDraft ? '；编辑草稿已保留' : ''}',
    );
  });

  List<KernelLog> pausedLines = [];
  (bool, bool, bool)? desktopState;

  void _syncDesktop() {
    final state = (proxy.running, locked, canApply);
    if (desktopState == state) return;
    desktopState = state;
    unawaited(
      native
          .updateState(running: state.$1, busy: state.$2, canApply: state.$3)
          .catchError((Object error) {
            desktopState = null;
          }),
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _load();
  }

  void _logsChanged() {
    if (active && !pauseLogs && page == 3 && followLogs) scrollToLatest();
  }

  void _proxyChanged() {
    if (!active) return;
    if (!working) _acceptKernelConfiguration();
    update(() {});
    _syncDesktop();
    if (!pauseLogs && page == 3 && followLogs) scrollToLatest();
  }

  void _acceptKernelConfiguration() {
    final profile = proxy.appliedProfile;
    if (active &&
        proxy.connected &&
        !proxy.configurationChanged &&
        profile != null &&
        !identical(profile, _acceptedKernelProfile)) {
      if (baseRevision != proxy.configurationRevision ||
          _acceptedKernelGeneration != proxy.kernelGeneration) {
        accept(profile);
      } else {
        // 同版本快照只更新引用，普通重订阅不会清空仍有效的编辑内容。
        _acceptedKernelProfile = profile;
      }
    }
  }

  void scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (active && logScroll.hasClients) {
        logScroll.jumpTo(logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _load() async {
    try {
      final env = await native.environment();
      if (!active) return;
      update(() => sidebarMaterial = env['sidebarMaterial'] == 'true');
      resources = env['resources']!;
      proxy.directory = Directory(env['support']!);
      try {
        final appearance = await appearancePreferences.read(proxy.directory);
        if (!active) return;
        themeMode.value = appearance;
      } catch (_) {
        message('读取外观设置失败，暂时跟随系统外观。', failure: true);
      }
      if (!active) return;
      final profile = ProxyProfile();
      if (!usesNativeKernel) {
        final runtime = await preferences.read(proxy.directory);
        profile.javaPath = runtime.javaPath;
        profile.jarPath = runtime.jarPath;
      }
      if (!active) return;
      java.text = profile.javaPath;
      jar.text = profile.jarPath;
      if (!active) return;
      accept(profile);
      baseRevision = null;
      dirty = true;
      final launch =
          usesNativeKernel ||
          profile.jarPath.isNotEmpty ||
          const String.fromEnvironment('PROXY_JAR').isNotEmpty;
      await proxy.connect(profile, resources, launch: launch);
      if (!active) return;
      if (proxy.connected) {
        final applied = proxy.appliedProfile!;
        accept(applied);
        if (!proxy.running) {
          if (applied.connections.isEmpty && applied.routingMode != 'direct') {
            message('请先添加连接并应用配置，再启动代理');
          } else {
            try {
              await proxy.start(applied, resources, applyDraft: false);
            } catch (e) {
              message('自动启动代理失败：${proxy.redact(e.toString())}', failure: true);
            }
          }
        }
      }
    } catch (e) {
      message('加载配置失败：$e', failure: true);
    }
    if (active) {
      update(() {
        loading = false;
      });
      _syncDesktop();
    }
  }

  ProxyProfile draftProfile() {
    captureConnection();
    return ProxyProfile(
      values: fields.map(
        (key, controller) => MapEntry(key, controller.text.trim()),
      ),
      connections: connectionDrafts.map((c) => c.copy()).toList(),
      defaultConnectionId: defaultId,
      rules: rules.text,
      routesFile: routesFile.text.trim(),
      routesOverrides: _acceptedKernelProfile?.routesOverrides ?? '',
      routingMode: _acceptedKernelProfile?.routingMode ?? 'rules',
      inlineRules: inlineRules,
      javaPath: java.text.trim(),
      jarPath: jar.text.trim(),
    );
  }

  void changed(String _) => update(() {
    captureConnection();
    dirty = true;
  });

  void message(String text, {bool failure = false}) {
    if (active) messages.add(UiMessage(text, failure: failure));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (!active || savingAppearance || themeMode.value == mode) return;
    final previous = themeMode.value;
    update(() => savingAppearance = true);
    themeMode.value = mode;
    try {
      await appearancePreferences.write(proxy.directory, mode);
    } catch (_) {
      if (active) {
        themeMode.value = previous;
        message('保存外观设置失败，已恢复原来的主题，请重试。', failure: true);
      }
    } finally {
      if (active) update(() => savingAppearance = false);
    }
  }

  Future<void> saveRuntime() => action(() async {
    await preferences.write(
      proxy.directory,
      RuntimePaths(java.text.trim(), jar.text.trim()),
    );
    message('启动路径已保存；退出内核后，下次启动使用这些路径');
  });

  Future<void> start() => action(() async {
    final profile = draftProfile();
    await ensureKernel();
    final appliedRevision = await proxy.start(
      profile,
      resources,
      applyDraft: dirty,
      expectedRevision: baseRevision,
    );
    if (active && appliedRevision != null) {
      update(() => accept(proxy.appliedProfile!));
    }
  });

  Future<void> stop() => action(proxy.stop);
  Future<void> refreshTunService() async {
    if (!supportsTunService || !active || checkingTunService) return;
    update(() {
      checkingTunService = true;
      tunServiceError = '';
    });
    try {
      final installed = await native.tunServiceInstalled();
      if (active) update(() => tunServiceInstalled = installed);
    } catch (error) {
      if (active) update(() => tunServiceError = '读取辅助服务状态失败：$error');
    } finally {
      if (active) update(() => checkingTunService = false);
    }
  }

  Future<void> removeTunService() => action(() async {
    if (proxy.tunEnabled) throw StateError('请先关闭虚拟网卡模式，再卸载辅助服务');
    await native.removeTunService();
    await refreshTunService();
    if (tunServiceInstalled != false || tunServiceError.isNotEmpty) {
      throw StateError('尚未确认辅助服务已卸载，请刷新状态后重试');
    }
    message('系统辅助服务已卸载，配置和访问记录已保留');
  });

  Future<void> setTun(bool enabled) => action(() async {
    if (!enabled) {
      await proxy.stopTun();
      return;
    }
    final ticket = await proxy.requestTun();
    _tunTicket = ticket;
    try {
      await native.startTun(proxy.endpointFile.path, ticket);
    } catch (_) {
      await proxy.stopTun();
      rethrow;
    }
  });

  Future<void> restart() => action(proxy.restart);
  Future<void> disconnect() => action(proxy.disconnect);
  Future<void> shutdown() => action(proxy.shutdown);

  /// 合并重复退出请求；内核完成退出或发现文件已移除后允许客户端退出。
  Future<bool> prepareToExit() =>
      _exitRequest ??= _prepareToExit().whenComplete(() => _exitRequest = null);

  Future<bool> _prepareToExit() async {
    if (locked) {
      await native.showWindow();
      message('正在处理其他操作，请完成后再退出', failure: true);
      return false;
    }
    update(() => working = true);
    try {
      await proxy.shutdown();
      return true;
    } catch (e) {
      await native.showWindow();
      message(
        '内核退出失败，已取消退出：${proxy.redact(e.toString().replaceFirst('Bad state: ', ''))}',
        failure: true,
      );
      return false;
    } finally {
      update(() => working = false);
    }
  }

  Future<void> validateConfiguration() => action(() async {
    await ensureKernel();
    await proxy.validateConfiguration(draftProfile());
    message('配置校验通过，尚未应用');
  });
  Future<void> validateRules() => action(() async {
    await proxy.validateRules(draftProfile(), resources);
    message('规则校验通过');
  });
  Future<void> reloadRules() => action(() async {
    await proxy.reloadRules(expectedRevision: baseRevision);
    if (active) update(() => accept(proxy.appliedProfile!));
    message('文件规则已重新载入');
  });
  Future<void> diagnose({String? profileId}) =>
      action(() => proxy.diagnose(target.text.trim(), profileId: profileId));
  Future<void> cancelDiagnostic(String id) =>
      action(() => proxy.cancelOperation(id));
  Future<void> exportLogs(List<KernelLog> lines) => action(() async {
    final path = await native.exportLogs(lines.join('\n'));
    if (path != null) message('当前显示的日志已导出');
  });
  void toggleLogPause() => update(() {
    pauseLogs = !pauseLogs;
    if (pauseLogs) pausedLines = List.of(proxy.logs);
  });
  void clearLogs() {
    proxy.clearLogs();
    update(() => pausedLines = []);
  }

  Future<void> choose(String kind, TextEditingController controller) async {
    try {
      final path = await native.chooseFile(kind);
      if (path == null || !active) return;
      final value = kind == 'rules' ? await File(path).readAsString() : path;
      if (!active) return;
      controller.text = value;
      if (active && kind != 'java' && kind != 'jar') changed('');
    } catch (e) {
      message('读取文件失败：$e', failure: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(messages.close());
    proxy.removeListener(_proxyChanged);
    proxy.logChanges.removeListener(_logsChanged);
    proxy.dispose();
    for (final controller in [
      ...fields.values,
      connectionName,
      rules,
      routesFile,
      target,
      java,
      jar,
    ]) {
      controller.dispose();
    }
    logScroll.dispose();
    themeMode.dispose();
    super.dispose();
  }

  bool get locked => loading || working || proxy.busy;
  bool get canApply => !locked && (page == 1 || page == 2);
  void navigate(int value) {
    if (value < 0 || value > 5) return;
    update(() => page = value);
    if (value == 3 && followLogs && !pauseLogs) scrollToLatest();
  }

  Future<void> handleNativeCall(MethodCall call) async {
    if (call.method == 'tunExited' && active) {
      final result = Map<String, dynamic>.from(call.arguments as Map);
      if (result['ticket'] != _tunTicket) return;
      if (proxy.tunState == 'authorizing') await proxy.stopTun();
      final error = result['error'] as String;
      if (error.isNotEmpty && active) {
        messages.add(UiMessage(error, failure: true));
      }
    }
    if (call.method == 'showSettings') navigate(1);
    if (call.method == 'navigate') navigate(call.arguments as int);
    if (call.method == 'applyConfiguration' && canApply) await apply();
    if (call.method == 'toggleProxy' && !locked) {
      await (proxy.running ? stop() : start());
      if (proxy.error.isNotEmpty) await native.showWindow();
    }
  }
}
