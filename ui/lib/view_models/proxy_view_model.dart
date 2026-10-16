import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/proxy_profile.dart';
import '../models/connection_document.dart';
import '../models/kernel_status.dart';
import '../models/database_settings.dart';
import '../models/tun_engine.dart';
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
    _controlState = _currentControlState;
    _connectionChoices = _currentConnectionChoices;
    _capabilities = Set.of(this.proxy.capabilities);
    _traffic = this.proxy.traffic;
    _tunnels = List.of(this.proxy.tunnels);
    _operations = Map.of(this.proxy.operations);
    _overviewState = _currentOverviewState;
    this.proxy.addListener(_proxyChanged);
    this.proxy.logChanges.addListener(_logsChanged);
  }
  String _tunTicket = '';
  Completer<String>? _tunExit;
  TunEngine _tunEngine = TunEngine.outline;
  TunEngine get tunEngine => proxy.tunEnabled ? proxy.tunEngine : _tunEngine;
  bool switchingTunEngine = false;
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
  // 高频数据各自通知使用它的区域，配置和交互状态仍沿用主视图模型。
  final trafficChanges = ChangeNotifier();
  final tunnelChanges = ChangeNotifier();
  final operationChanges = ChangeNotifier();
  final overviewChanges = ChangeNotifier();
  late Object _controlState, _overviewState;
  late List<(String, String, String)> _connectionChoices;
  late Set<String> _capabilities;
  TrafficSnapshot? _traffic;
  late List<TunnelStatus> _tunnels;
  late Map<String, DiagnosticOperation> _operations;

  Object get _currentControlState => (
    proxy.busy,
    proxy.changingDatabase,
    proxy.storageBackend,
    proxy.running,
    proxy.connected,
    proxy.streaming,
    proxy.tunState,
    proxy.tunError,
    proxy.tunEngine,
    proxy.configurationChanged,
    proxy.revision,
    proxy.configurationRevision,
    proxy.kernelGeneration,
    proxy.networkGeneration,
    proxy.routingMode,
    proxy.connection,
    proxy.address,
    proxy.error,
    proxy.defaultConnectionId,
    proxy.appliedProfile,
    proxy.historyStorageWarning,
  );
  List<(String, String, String)> get _currentConnectionChoices => [
    for (final connection in proxy.connections)
      (connection.id, connection.name, connection.protocol),
  ];
  Object get _currentOverviewState => (
    proxy.overviewOperation('latency'),
    proxy.overviewBusy('latency'),
    proxy.overviewOperation('exit-ip'),
    proxy.overviewBusy('exit-ip'),
    proxy.overviewOperation('websites'),
    proxy.overviewBusy('websites'),
  );
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
  final target = TextEditingController(text: 'www.google.com:443');
  bool followLogs = true;
  bool working = false;
  bool routingModeChanging = false;
  bool get showBlockingProgress => locked && !routingModeChanging;
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
    baseRevision = proxy.configurationRevision;
    dirty = false;
    routesConflict = false;
    rulesError = '';
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

  Future<void> action(
    Future<void> Function() action, {
    bool preserveDrafts = false,
    bool routingModeChange = false,
  }) async {
    if (working || !active) return;
    update(() {
      working = true;
      routingModeChanging = routingModeChange;
    });
    try {
      await action();
    } catch (e) {
      if (proxy.configurationChanged ||
          e is KernelApiException &&
              (e.code == 'REVISION_CONFLICT' || e.code == 'KERNEL_RESTARTED')) {
        final keepDrafts = preserveDrafts || routesConflict;
        if (keepDrafts) routesConflict = true;
        try {
          await proxy.refreshConfiguration();
          if (active) {
            update(() {
              if (keepDrafts) {
                routesConflict = true;
              } else {
                accept(proxy.appliedProfile!);
              }
            });
          }
          message(
            keepDrafts ? '内核配置已变化，编辑草稿已保留，请重新读取并核对配置' : '已同步内核最新配置，请核对后重新操作',
            failure: true,
          );
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
          routingModeChanging = false;
          _acceptKernelConfiguration();
        });
      }
    }
  }

  Future<void> apply() => action(() async {
    if (routesConflict) throw StateError('请先在路由规则页核对配置冲突');
    final profile = draftProfile();
    await ensureKernel();
    await proxy.apply(profile, resources, expectedRevision: baseRevision);
    if (active) update(() => accept(proxy.appliedProfile!));
    message('配置已应用并保存到内核');
  });

  Future<void> switchConnection(String id) => action(() async {
    if (routesConflict) throw StateError('请先在路由规则页核对配置冲突');
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

  Future<void> setRoutingMode(String mode) => action(
    () async {
      if (routesConflict) throw StateError('请先在路由规则页核对配置冲突');
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
          } else if (proxy.configurationRevision == appliedRevision &&
              _acceptedKernelGeneration == proxy.kernelGeneration) {
            accept(proxy.appliedProfile!);
          } else {
            routesConflict = true;
          }
        });
      }
      // 成功由模式选中态直接反馈，避免连续切换时成功提示排队播放。
    },
    preserveDrafts: true,
    routingModeChange: true,
  );

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
    if (routesConflict && (proxy.configurationChanged || !proxy.connected)) {
      message('请先重新读取内核配置，再放弃草稿', failure: true);
      return;
    }
    // 冲突后必须恢复最新快照，不能给旧配置套用新版本号。
    update(
      () => accept(
        routesConflict ? proxy.appliedProfile! : _acceptedKernelProfile!,
      ),
    );
  }

  Future<bool> routeTarget(String target, String route) async {
    var saved = false;
    await action(() async {
      if (routesConflict) throw StateError('请先核对内核配置冲突');
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
          } else if (proxy.configurationRevision == appliedRevision &&
              _acceptedKernelGeneration == proxy.kernelGeneration) {
            accept(proxy.appliedProfile!);
          } else {
            routesConflict = true;
          }
        });
      }
      saved = !routesConflict;
      if (!saved) throw StateError('内核配置再次变化，草稿已保留，请重新读取并核对配置');
      message(
        '${route == 'auto' ? '已移除指定规则' : '目标已切换为${route == 'direct' ? '直连' : '代理'}'}并保存；路由变化的连接已断开，请求重连后生效${keepDraft ? '；编辑草稿已保留' : ''}',
      );
    }, preserveDrafts: true);
    return saved;
  }

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
    final control = _currentControlState;
    final choices = _currentConnectionChoices;
    final overview = _currentOverviewState;
    final controlChanged =
        control != _controlState ||
        !listEquals(choices, _connectionChoices) ||
        !setEquals(proxy.capabilities, _capabilities);
    final trafficChanged = !identical(_traffic, proxy.traffic);
    final tunnelsChanged = !listEquals(_tunnels, proxy.tunnels);
    final operationsChanged = !mapEquals(_operations, proxy.operations);
    final overviewChanged = overview != _overviewState;
    // 先更新比较快照，再通知订阅者，避免同步回调重复派发同一份状态。
    _controlState = control;
    _connectionChoices = choices;
    _capabilities = Set.of(proxy.capabilities);
    _traffic = proxy.traffic;
    if (tunnelsChanged) _tunnels = List.of(proxy.tunnels);
    if (operationsChanged) _operations = Map.of(proxy.operations);
    _overviewState = overview;
    if (controlChanged) {
      if (!working) _acceptKernelConfiguration();
      update(() {});
    }
    if (trafficChanged) trafficChanges.notifyListeners();
    if (tunnelsChanged) tunnelChanges.notifyListeners();
    if (operationsChanged) operationChanges.notifyListeners();
    if (overviewChanged) overviewChanges.notifyListeners();
  }

  void _acceptKernelConfiguration() {
    if (routesConflict) return;
    final profile = proxy.appliedProfile;
    if (active &&
        proxy.connected &&
        !proxy.configurationChanged &&
        profile != null &&
        !identical(profile, _acceptedKernelProfile)) {
      if (baseRevision != proxy.configurationRevision ||
          _acceptedKernelGeneration != proxy.kernelGeneration) {
        if (rulesDirty) {
          routesConflict = true;
        } else {
          accept(profile);
        }
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
      final runtime = await preferences.read(proxy.directory);
      _tunEngine = runtime.tunEngine;
      if (!usesNativeKernel) {
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
      routesOverrides: _acceptedKernelProfile?.routesOverrides ?? '',
      routingMode: _acceptedKernelProfile?.routingMode ?? 'rules',
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

  Future<void> changeDatabase(DatabaseSettings settings) => action(() async {
    if (dirty && proxy.connected) throw StateError('请先应用或放弃代理配置草稿，再切换数据库');
    await proxy.changeDatabase(settings, draftProfile(), resources);
    if (active) update(() => accept(proxy.appliedProfile!));
    message('数据库已切换为 ${settings.label}，请确认配置后启动代理');
  });

  Future<void> saveRuntime() => action(() async {
    await preferences.write(
      proxy.directory,
      RuntimePaths(java.text.trim(), jar.text.trim(), tunEngine: _tunEngine),
    );
    message('启动路径已保存；退出内核后，下次启动使用这些路径');
  });

  Future<void> start() => action(() async {
    if (routesConflict) throw StateError('请先在路由规则页核对配置冲突');
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
    await _waitTunExit();
    if (!active) return;
    await _startTun();
  });

  Future<void> _startTun() async {
    final ticket = await proxy.requestTun(_tunEngine);
    _tunTicket = ticket;
    final exit = Completer<String>();
    _tunExit = exit;
    try {
      await native.startTun(proxy.endpointFile.path, ticket);
    } catch (_) {
      if (!exit.isCompleted) exit.complete('');
      if (identical(_tunExit, exit)) _tunExit = null;
      await proxy.stopTun();
      rethrow;
    }
  }

  Future<void> _waitTunExit() async {
    final exit = _tunExit;
    if (exit == null) return;
    final error = await exit.future.timeout(
      const Duration(seconds: 135),
      onTimeout: () => throw StateError('等待虚拟网卡辅助进程退出超时，请完成系统授权或检查辅助服务'),
    );
    if (identical(_tunExit, exit)) _tunExit = null;
    if (error.isNotEmpty) throw StateError(error);
  }

  Future<void> setTunEngine(TunEngine engine) => action(() async {
    if (engine == tunEngine) return;
    if (!proxy.tunSupported) throw StateError('当前内核不支持虚拟网卡');
    if ({'authorizing', 'starting', 'stopping'}.contains(proxy.tunState)) {
      throw StateError('请等待虚拟网卡启停完成后再切换组件');
    }
    final restart = proxy.tunState == 'running';
    update(() => switchingTunEngine = true);
    try {
      if (restart) await proxy.stopTun();
      await _waitTunExit();
      if (restart) await proxy.waitTunStopped();
      if (!active) return;
      final saved = await preferences.read(proxy.directory);
      await preferences.write(
        proxy.directory,
        RuntimePaths(saved.javaPath, saved.jarPath, tunEngine: engine),
      );
      if (!active) return;
      update(() => _tunEngine = engine);
      if (restart) await _startTun();
    } finally {
      if (active) update(() => switchingTunEngine = false);
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

  bool routesConflict = false;
  String rulesError = '';
  bool get rulesDirty => rules.text != (_acceptedKernelProfile?.rules ?? '');
  String? routeQueryId;
  String routeQueryTarget = '';
  int? _routeQueryRevision;
  int? _routeQueryGeneration;
  DiagnosticOperation? get routeQuery => proxy.operations[routeQueryId];
  bool get routeQueryStale =>
      !proxy.connected ||
      _routeQueryRevision != proxy.revision ||
      _routeQueryGeneration != proxy.kernelGeneration;

  void _refreshDirty() {
    dirty =
        _acceptedKernelProfile == null ||
        jsonEncode(draftProfile().runtimeConfiguration) !=
            jsonEncode(_acceptedKernelProfile!.runtimeConfiguration);
  }

  void editRules(String text) => update(() {
    if (rules.text != text) rules.text = text;
    rulesError = '';
    _refreshDirty();
  });

  void discardRules() {
    if (locked) return;
    editRules(_acceptedKernelProfile?.rules ?? '');
  }

  /// 只提交直连规则；其他表单的草稿继续保留。
  Future<void> applyRules() => action(() async {
    if (!proxy.connected) throw StateError('请先连接代理内核');
    if (routesConflict) throw StateError('请先核对内核配置冲突');
    if (!rulesDirty) return;
    captureConnection();
    rulesError = '';
    final int appliedRevision;
    try {
      appliedRevision = await proxy.updateDirectRules(
        rules.text,
        expectedRevision: baseRevision,
      );
    } catch (e) {
      rulesError = proxy.redact(e.toString());
      rethrow;
    }
    if (!active) return;
    update(() {
      if (proxy.configurationRevision != appliedRevision ||
          _acceptedKernelGeneration != proxy.kernelGeneration) {
        routesConflict = true;
        rulesError = '提交后配置再次变化，草稿已保留，请重新读取并核对配置';
        return;
      }
      _acceptedKernelProfile = proxy.appliedProfile;
      baseRevision = appliedRevision;
      rules.text = proxy.appliedProfile!.rules;
      _refreshDirty();
    });
    if (!routesConflict) message('直连规则已应用并保存；路由变化的连接需要重新建立');
  }, preserveDrafts: true);

  Future<bool> validateRuleDraft(String text) async {
    var valid = false;
    await action(() async {
      if (!proxy.connected) throw StateError('请先连接代理内核');
      await proxy.validateDirectRules(text);
      valid = true;
    }, preserveDrafts: true);
    return valid;
  }

  Future<void> queryRoute(String target) => action(() async {
    if (!proxy.connected) throw StateError('请先连接代理内核');
    routeQueryId = null;
    routeQueryTarget = target;
    _routeQueryRevision = proxy.revision;
    _routeQueryGeneration = proxy.kernelGeneration;
    routeQueryId = await proxy.resolveRoute(target);
  });

  Future<void> validateConfiguration() => action(() async {
    await ensureKernel();
    await proxy.validateConfiguration(draftProfile());
    message('配置校验通过，尚未应用');
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

  Future<Map<String, dynamic>?> readConfigurationDocument() async {
    Map<String, dynamic>? document;
    await action(() async {
      final path = await native.chooseFile('json');
      if (path == null) return;
      final file = File(path);
      if (await file.length() > 1048576) throw StateError('配置文件不能超过 1 MB');
      final Object? value;
      try {
        value = jsonDecode(await file.readAsString());
      } on FormatException {
        throw const FormatException('配置文件不是有效的 JSON，请检查格式');
      }
      if (value is! Map<String, dynamic>) {
        throw const FormatException('配置文件必须是 JSON 对象');
      }
      document = value;
    }, preserveDrafts: true);
    return document;
  }

  Future<Map<String, dynamic>?> previewRoutingImport(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) async {
    Map<String, dynamic>? preview;
    await action(() async {
      if (dirty || routesConflict) throw StateError('请先应用或撤销当前草稿，再导入路由规则');
      preview = await proxy.previewRouting(document, strategy, revision);
    }, preserveDrafts: true);
    return preview;
  }

  Future<void> importRoutingDocument(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) => action(() async {
    if (dirty || routesConflict) throw StateError('请先应用或撤销当前草稿，再导入路由规则');
    final applied = await proxy.importRouting(document, strategy, revision);
    if (!active) return;
    if (proxy.configurationRevision != applied) {
      throw StateError('导入后配置已变化，请重新读取配置');
    }
    update(() => accept(proxy.appliedProfile!));
    message('路由规则已导入并保存');
  }, preserveDrafts: true);

  Future<void> exportRoutingDocument() => action(() async {
    final document = await proxy.exportRouting();
    final path = await native.exportDocument(
      'network-路由规则.json',
      const JsonEncoder.withIndent('  ').convert(document),
    );
    if (path != null) message('已应用的路由规则已导出');
  }, preserveDrafts: true);

  Future<void> exportConnectionDocument(
    List<String> ids,
    bool includePassword,
  ) => action(() async {
    final document = await proxy.exportConnections(ids, includePassword);
    final path = await native.exportDocument(
      'network-连接配置.json',
      const JsonEncoder.withIndent('  ').convert(document),
    );
    if (path != null) message('已保存的连接配置已导出');
  }, preserveDrafts: true);

  void importConnectionDrafts(
    List<ConnectionProfile> incoming,
    List<String?> replacements,
  ) {
    captureConnection();
    final next = ConnectionDocument.merge(
      connectionDrafts,
      incoming,
      replacements,
      'node-${DateTime.now().microsecondsSinceEpoch}',
    );
    update(() {
      connectionDrafts = next;
      if (defaultId.isEmpty) defaultId = next.first.id;
      showConnection(next.firstWhere((c) => c.id == defaultId));
      _refreshDirty();
    });
    message('连接已导入草稿，请核对密码与证书后应用保存');
  }

  Future<String?> readRulesFile() async {
    String? text;
    await action(() async {
      final path = await native.chooseFile('rules');
      if (path != null) text = await File(path).readAsString();
    });
    return text;
  }

  Future<void> choose(String kind, TextEditingController controller) async {
    try {
      final path = await native.chooseFile(kind);
      if (path == null || !active) return;
      controller.text = path;
      if (active && kind != 'java' && kind != 'jar') changed('');
    } catch (e) {
      message('读取文件失败：$e', failure: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final exit = _tunExit;
    _tunExit = null;
    if (exit != null && !exit.isCompleted) exit.complete('');
    unawaited(messages.close());
    proxy.removeListener(_proxyChanged);
    proxy.logChanges.removeListener(_logsChanged);
    proxy.dispose();
    for (final controller in [
      ...fields.values,
      connectionName,
      rules,
      target,
      java,
      jar,
    ]) {
      controller.dispose();
    }
    logScroll.dispose();
    themeMode.dispose();
    trafficChanges.dispose();
    tunnelChanges.dispose();
    operationChanges.dispose();
    overviewChanges.dispose();
    super.dispose();
  }

  bool get locked => loading || working || proxy.busy || proxy.changingDatabase;
  bool get canApply =>
      !locked &&
      (page == 1 ||
          page == 2 && rulesDirty && proxy.connected && !routesConflict);
  Future<void> applyCurrentPage() => page == 2 ? applyRules() : apply();
  void navigate(int value) {
    if (value < 0 || value > 5) return;
    update(() => page = value);
    if (value == 3 && followLogs && !pauseLogs) scrollToLatest();
  }

  Future<void> handleNativeCall(MethodCall call) async {
    if (call.method == 'tunExited' && active) {
      final result = Map<String, dynamic>.from(call.arguments as Map);
      if (result['ticket'] != _tunTicket) return;
      var error = result['error'] as String;
      try {
        await proxy.cancelTunAuthorization();
      } catch (cleanupError) {
        final detail = proxy.redact(
          cleanupError.toString().replaceFirst('Bad state: ', ''),
        );
        error = '${error.isEmpty ? '' : '$error；'}撤销虚拟网卡启动失败：$detail';
      } finally {
        final exit = _tunExit;
        _tunExit = null;
        if (exit != null && !exit.isCompleted) exit.complete(error);
      }
      if (error.isNotEmpty && active && !switchingTunEngine) {
        messages.add(UiMessage(error, failure: true));
      }
    }
    if (call.method == 'showSettings') navigate(1);
    if (call.method == 'navigate') navigate(call.arguments as int);
    if (call.method == 'applyConfiguration' && canApply) {
      await applyCurrentPage();
    }
    if (call.method == 'toggleProxy' && !locked) {
      await (proxy.running ? stop() : start());
      if (proxy.error.isNotEmpty) await native.showWindow();
    }
  }
}
