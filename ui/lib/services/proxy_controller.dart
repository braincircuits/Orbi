import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/proxy_profile.dart';
import '../models/database_settings.dart';
import 'database_preferences.dart';
import '../models/kernel_status.dart';
import '../models/tun_engine.dart';
import '../models/traffic_summary.dart';
import 'kernel_api_client.dart';

/// 打包的 Java 25 在持续输出零版本号时会错误编译此方法，产生 NUL 数字。
/// 仅禁用 Gson 写入 long 的编译，代理转发和其他方法仍正常使用即时编译。
const kernelJvmArguments = [
  '--enable-native-access=ALL-UNNAMED',
  '-XX:CompileCommand=quiet',
  '-XX:CompileCommand=exclude,com/google/gson/stream/JsonWriter.value,(J)Lcom/google/gson/stream/JsonWriter;',
];

/// 应用包直接执行内置内核启动程序；PROXY_NATIVE 用于开发时指定原生构建产物。
String nativeKernelExecutable(String resources) {
  final bundled =
      '$resources/proxy/network-core${Platform.isWindows ? '.exe' : ''}';
  return File(bundled).existsSync()
      ? bundled
      : const String.fromEnvironment('PROXY_NATIVE');
}

class KernelLog {
  KernelLog(this.id, this.level, this.message, this.time);
  factory KernelLog.fromJson(Map<String, dynamic> value) => KernelLog(
    value['id'] as int,
    '${value['level']}',
    '${value['message']}',
    '${value['time']}',
  );
  final int id;
  final String level, message, time;
  @override
  String toString() => '${time.isEmpty ? '' : '$time '} $level $message';
}

/// HTTP 负责命令，SSE 负责推送；释放界面资源不会退出独立运行的内核。
class ProxyController extends ChangeNotifier {
  ProxyController({
    Directory? directory,
    KernelApiClient? api,
    DatabasePreferences? databases,
  }) : _api = api ?? KernelApiClient(),
       databases = databases ?? DatabasePreferences(),
       directory =
           directory ??
           Directory(
             '${Platform.environment['HOME']}/Library/Application Support/NetworkUI',
           );
  Directory directory;
  final DatabasePreferences databases;
  DatabaseSettings? _databaseSettings;
  DatabaseSettings get databaseSettings =>
      _databaseSettings ?? DatabaseSettings(path: configPath);
  String storageBackend = '';
  bool changingDatabase = false;
  File get endpointFile => File('${directory.path}/run/control.json');
  String get configPath => '${directory.path}/kernel.db';
  bool get canShutdown => _base != null && _token.isNotEmpty;
  final KernelApiClient _api;
  final logChanges = ChangeNotifier();
  HttpClient? _events;
  Uri? _base;
  String _token = '', _lastEventId = '';
  int _epoch = 0;
  bool _disposed = false, _subscribed = false;
  Future<void>? _connecting;
  Completer<void>? _operationDone;
  Timer? _retry;
  int _retrySeconds = 1;
  bool busy = false, running = false, connected = false, streaming = false;
  String tunState = 'off', tunError = '';
  TunEngine tunEngine = TunEngine.outline;
  bool get tunEnabled =>
      {'authorizing', 'starting', 'running', 'stopping'}.contains(tunState);
  bool get tunSupported =>
      Platform.isMacOS && capabilities.contains('macosTun');
  bool configurationChanged = false;
  int revision = 0, configurationRevision = 0;
  int kernelGeneration = 0, networkGeneration = 0;
  String routingMode = 'rules';
  final _overviewIds = <String, String>{};
  final _overviewStarting = <String>{};

  DiagnosticOperation? overviewOperation(String kind) {
    if (!connected ||
        !running ||
        kind == 'latency' && routingMode == 'direct') {
      return null;
    }
    final operation = _operations[_overviewIds[kind]];
    return operation?.context['generation'] == networkGeneration
        ? operation
        : null;
  }

  bool overviewBusy(String kind) =>
      _overviewStarting.contains(kind) ||
      overviewOperation(kind) != null && !overviewOperation(kind)!.finished;
  String connection = 'idle',
      address = '',
      error = '',
      defaultConnectionId = '';
  List<ConnectionStatus> connections = const [];
  List<TunnelStatus> tunnels = const [];
  TrafficSnapshot? traffic;
  String historyStorageWarning = '';
  Future<TrafficSummary> trafficSummary({bool hourly = true}) async {
    final result = await _request(
      'GET',
      hourly ? 'traffic/history' : 'traffic/trend',
    );
    return TrafficSummary.fromJson(result['data'] as Map<String, dynamic>);
  }

  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) async {
    final query = Uri(
      queryParameters: {
        'target': target,
        'failedOnly': '$failedOnly',
        'order': order,
        'ascending': '$ascending',
        'limit': '100',
        if (beforeValue != null) 'beforeValue': '$beforeValue',
        'afterHost': afterHost,
      },
    ).query;
    final result = await _request('GET', 'access-records?$query');
    return AccessRecordPage.fromJson(result['data'] as Map<String, dynamic>);
  }

  /// 概览和列表统一按全部业务隧道统计，包含代理与直连。
  int get activeTunnelCount =>
      tunnels.where((tunnel) => tunnel.state == 'active').length;
  int get pendingTunnelCount => tunnels.length - activeTunnelCount;
  Set<String> capabilities = {};
  ProxyProfile? appliedProfile;
  final _logs = <KernelLog>[];
  List<KernelLog> get logs => UnmodifiableListView(_logs);
  final _operations = <String, DiagnosticOperation>{};
  Map<String, DiagnosticOperation> get operations =>
      UnmodifiableMapView(_operations);
  final Set<String> _secrets = {};
  int _localLogId = 0;
  String _javaPath = '', _jarPath = '';
  bool _instanceChanged = false;

  void _notifyLogs() {
    if (!_disposed) logChanges.notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String redact(String text) {
    for (final secret in _secrets) {
      text = text.replaceAll(secret, '***');
    }
    if (_token.isNotEmpty) text = text.replaceAll(_token, '***');
    if (databaseSettings.password.isNotEmpty) {
      text = text.replaceAll(databaseSettings.password, '***');
    }
    return text;
  }

  void addLog(String text) {
    if (_disposed) return;
    final split = text.indexOf(' ');
    _logs.add(
      KernelLog(
        --_localLogId,
        split < 0 ? 'INFO' : text.substring(0, split),
        redact(split < 0 ? text : text.substring(split + 1)),
        '',
      ),
    );
    _trimLogs();
    _notifyLogs();
  }

  void _trimLogs() {
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
  }

  void clearLogs() {
    _logs.clear();
    _notifyLogs();
  }

  void _log(Map<String, dynamic> data) {
    final item = KernelLog.fromJson(data);
    if (_logs.any((entry) => entry.id == item.id)) return;
    _logs.add(KernelLog(item.id, item.level, redact(item.message), item.time));
    _trimLogs();
  }

  void _metadata(Map<String, dynamic> value) {
    final incoming = value['revision'] as int?;
    if (incoming == null || incoming < revision) return;
    revision = incoming;
    configurationChanged =
        _instanceChanged || revision != configurationRevision;
  }

  void _status(Map<String, dynamic> status) {
    if ((status['revision'] as int? ?? revision) < revision) return;
    final generation = status['networkGeneration'] as int? ?? 0;
    if (generation < networkGeneration) return;
    _metadata(status);
    if (generation != networkGeneration || status['running'] != true) {
      _overviewIds.clear();
    }
    networkGeneration = generation;
    routingMode = '${status['routingMode'] ?? 'rules'}';
    running = status['running'] == true;
    final tun = status['tun'] as Map<String, dynamic>?;
    tunState = tun?['state'] as String? ?? 'off';
    tunError = tun?['error'] as String? ?? '';
    if (tun?['engine'] case final String engine) {
      tunEngine = TunEngine.parse(engine);
    }
    connection = '${status['connection'] ?? 'idle'}';
    address = '${status['address'] ?? ''}';
    defaultConnectionId = '${status['defaultConnectionId'] ?? ''}';
    connections = (status['connections'] as List? ?? [])
        .map((v) => ConnectionStatus.fromJson(v as Map<String, dynamic>))
        .toList();
    tunnels = (status['tunnels'] as List? ?? [])
        .map((v) => TunnelStatus.fromJson(v as Map<String, dynamic>))
        .toList();
    traffic = TrafficSnapshot.merge(
      traffic,
      status['traffic'] as Map<String, dynamic>,
    );
    final storage = status['historyStorage'] as Map<String, dynamic>;
    final dropped = storage['droppedRecords'] as int;
    historyStorageWarning = [
      if ((storage['error'] as String).isNotEmpty) storage['error'] as String,
      if (dropped > 0) '有 $dropped 条历史事件未保存，请检查运行日志',
    ].join('；');
    final failure = '${status['error'] ?? ''}';
    if (failure.isNotEmpty) error = failure;
    _notify();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    int? expectedRevision,
  }) async {
    if (_base == null) throw StateError('尚未连接代理内核');
    if (expectedRevision != null && _instanceChanged) {
      throw KernelApiException('KERNEL_RESTARTED', '内核已重启，请等待配置同步后重新操作');
    }
    try {
      final result = await _api.request(
        _base!,
        _token,
        method,
        path,
        body: body,
        expectedRevision: expectedRevision,
      );
      _metadata(result);
      return result;
    } on KernelApiException catch (error) {
      if (error.code == 'REVISION_CONFLICT') configurationChanged = true;
      if (error.statusCode == 401) connected = false;
      rethrow;
    }
  }

  Future<bool> attach() async {
    if (!await endpointFile.exists()) return false;
    final value =
        jsonDecode(await endpointFile.readAsString()) as Map<String, dynamic>;
    final uri = Uri.parse(value['url'] as String);
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        value['apiVersion'] != 1 ||
        value['token'] is! String ||
        (value['token'] as String).length < 32) {
      throw StateError('内核发现文件无效：只允许 API v1 的本机管理地址');
    }
    final token = value['token'] as String;
    final changed = token != _token;
    _base = uri;
    _token = token;
    final info = await _request('GET', 'info');
    final data = info['data'] as Map<String, dynamic>;
    if (data['apiVersion'] != 1) throw StateError('代理内核 API 版本不兼容');
    capabilities = Set<String>.from(data['capabilities'] as List);
    if (!capabilities.containsAll({
      'events',
      'hotSettings',
      'hotRoutes',
      'hotProfiles',
      'tunnels',
      'targetRoutes',
      'routingMode',
      'overviewTests',
      'traffic',
      'persistentHistory',
      'sqlite',
      'postgresql',
      'mysql',
    })) {
      throw StateError('代理内核缺少所需的 Web 控制能力，请通过托盘退出旧版本后重新打开客户端');
    }
    storageBackend = data['storageBackend'] as String;
    if (!DatabaseSettings.labels.containsKey(storageBackend)) {
      throw StateError('内核数据库类型无效');
    }
    if (changed) {
      kernelGeneration++;
      networkGeneration = 0;
      _lastEventId = '';
      revision = info['revision'] as int;
      // 内核重启后的版本号可以从头开始，读取新配置前禁止沿用旧版本写入。
      if (appliedProfile != null) {
        configurationChanged = true;
        _instanceChanged = true;
      }
      _logs.clear();
      _operations.clear();
      _overviewIds.clear();
      traffic = null;
    }
    connected = true;
    _status((await _request('GET', 'status'))['data'] as Map<String, dynamic>);
    traffic = TrafficSnapshot.merge(
      traffic,
      (await _request('GET', 'traffic'))['data'] as Map<String, dynamic>,
    );
    return true;
  }

  Future<void> connect(
    ProxyProfile profile,
    String resources, {
    bool launch = true,
  }) async {
    if (_connecting != null) return _connecting;
    final pending = _connect(profile, resources, launch);
    _connecting = pending;
    try {
      await pending;
    } finally {
      _connecting = null;
    }
  }

  Future<void> _connect(
    ProxyProfile profile,
    String resources,
    bool launch,
  ) async {
    _databaseSettings = await databases.read(directory);
    if (connected) return;
    _javaPath = profile.javaPath;
    _jarPath = profile.jarPath;
    try {
      if (await attach()) {
        await refreshConfiguration();
        subscribe();
        return;
      }
    } on SocketException {
      // 仅连接被拒绝时允许启动新进程；鉴权或配置错误不可自动覆盖发现文件。
    }
    if (!launch) return;
    await directory.create(recursive: true);
    final lock = await File('${directory.path}/launch.lock')
        .open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    try {
      try {
        if (await attach()) {
          await refreshConfiguration();
          subscribe();
          return;
        }
      } on SocketException {
        /* 发现文件已过期。 */
      }
      final nativeKernel = nativeKernelExecutable(resources);
      var executable = nativeKernel;
      final arguments = <String>[];
      if (nativeKernel.isEmpty) {
        // JAR 启动仅用于开发环境；原生应用包不会回退到 JVM。
        final jar = profile.jarPath.isNotEmpty
            ? profile.jarPath
            : const String.fromEnvironment('PROXY_JAR');
        if (jar.isEmpty || !File(jar).existsSync()) {
          throw StateError('找不到代理内核，请在高级设置中选择新版 JAR');
        }
        var java = profile.javaPath.isNotEmpty
            ? profile.javaPath
            : const String.fromEnvironment('JAVA_PATH');
        final javaHome = Platform.environment['JAVA_HOME'];
        if (java.isEmpty &&
            javaHome != null &&
            File('$javaHome/bin/java').existsSync()) {
          java = '$javaHome/bin/java';
        }
        if (java.isEmpty && Platform.isMacOS) {
          final result = await Process.run('/usr/libexec/java_home', [
            '-v',
            '25',
          ]);
          if (result.exitCode != 0) {
            throw StateError('未找到 Java 25，请选择运行时或使用完整应用包');
          }
          java = '${result.stdout.toString().trim()}/bin/java';
        }
        if (java.isEmpty) java = 'java';
        executable = java;
        arguments.addAll([...kernelJvmArguments, '-jar', jar]);
      }
      arguments.addAll([
        '--web',
        if (await databases.file(directory).exists()) ...[
          '--storage-config',
          databases.file(directory).path,
        ] else ...[
          '--db',
          configPath,
        ],
        '--port',
        '0',
        '--endpoint-file',
        endpointFile.path,
      ]);
      final process = await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.detached,
        workingDirectory: directory.path,
      );
      var ready = false;
      for (var i = 0; i < 150 && !_disposed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!await endpointFile.exists()) continue;
        final discovery = jsonDecode(
          await endpointFile.readAsString(),
        ) as Map<String, dynamic>;
        if (discovery['pid'] != process.pid) continue;
        ready = await attach();
        if (ready) break;
      }
      if (!ready) {
        Process.killPid(process.pid);
        throw StateError(
          '内核启动失败或超时，请检查数据库地址、权限、密码及 TLS 设置。已保存本次选择，可在设置中修改或重新选择原数据库。',
        );
      }
      await refreshConfiguration();
      subscribe();
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  /// 显式停止旧内核后应用启动配置，失败也不退回其他数据库。
  Future<void> changeDatabase(
    DatabaseSettings settings,
    ProxyProfile profile,
    String resources,
  ) async {
    if (busy || changingDatabase) throw StateError('正在处理上一项操作');
    if (tunEnabled) throw StateError('请先关闭虚拟网卡，再切换数据库');
    settings.validate();
    changingDatabase = true;
    _notify();
    try {
      await shutdown();
      await databases.write(directory, settings);
      _databaseSettings = settings;
      storageBackend = '';
      appliedProfile = null;
      configurationChanged = _instanceChanged = false;
      revision = configurationRevision = 0;
      connections = const [];
      tunnels = const [];
      traffic = null;
      defaultConnectionId = '';
      historyStorageWarning = '';
      await connect(profile, resources);
      if (storageBackend != settings.type) {
        throw StateError('正在运行的内核与所选数据库不一致，请退出其他客户端后重试');
      }
    } finally {
      // 退出请求失败且旧内核仍连接时，恢复状态订阅。
      if (connected) subscribe();
      changingDatabase = false;
      _notify();
    }
  }

  Future<void> refreshConfiguration() async {
    final result = await _request('GET', 'config');
    appliedProfile = ProxyProfile.fromKernel(
      Map<String, dynamic>.from(result['data'] as Map<String, dynamic>),
      javaPath: _javaPath,
      jarPath: _jarPath,
    );
    configurationRevision = result['revision'] as int;
    _instanceChanged = false;
    configurationChanged =
        _instanceChanged || revision != configurationRevision;
    _notify();
  }

  Future<void> refreshLogs() async {
    final result = await _request('GET', 'logs?after=0&limit=500');
    final items = ((result['data'] as Map<String, dynamic>)['items'] as List);
    for (final entry in items) {
      _log(entry as Map<String, dynamic>);
    }
    _logs.sort((a, b) => a.id.compareTo(b.id));
    _trimLogs();
    _notifyLogs();
  }

  void subscribe() {
    if (_disposed || _subscribed) return;
    _subscribed = true;
    final epoch = ++_epoch;
    unawaited(_listen(epoch));
  }

  void unsubscribe() {
    _subscribed = false;
    ++_epoch;
    _retry?.cancel();
    _events?.close(force: true);
    _events = null;
    streaming = false;
  }

  Future<void> _listen(int epoch) async {
    if (!_subscribed || epoch != _epoch || _disposed) return;
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    _events = http;
    try {
      final request = await http
          .getUrl(_base!.resolve('/api/v1/events'))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (_lastEventId.isNotEmpty) {
        request.headers.set('Last-Event-ID', _lastEventId);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) {
        throw StateError('状态订阅失败（${response.statusCode}）');
      }
      streaming = connected = true;
      _retrySeconds = 1;
      _notify();
      var type = '', id = '';
      final data = <String>[];
      await for (final line
          in response
              .timeout(const Duration(seconds: 25))
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (epoch != _epoch || _disposed) return;
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            await _event(
              type,
              decodeKernelResponse(data.join('\n'), source: 'SSE /events'),
            );
            if (id.isNotEmpty) _lastEventId = id;
          }
          type = '';
          id = '';
          data.clear();
          continue;
        }
        if (line.startsWith(':')) continue;
        final split = line.indexOf(':');
        final key = split < 0 ? line : line.substring(0, split);
        var value = split < 0 ? '' : line.substring(split + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        switch (key) {
          case 'event':
            type = value;
          case 'id':
            id = value;
          case 'data':
            data.add(value);
        }
      }
    } catch (e) {
      if (epoch == _epoch && !_disposed) {
        error = '内核状态连接中断，正在重连：${redact(e.toString())}';
      }
    } finally {
      http.close(force: true);
      if (epoch == _epoch && _subscribed && !_disposed) {
        streaming = false;
        connected = false;
        _overviewIds.clear();
        _notify();
        _retry = Timer(Duration(seconds: _retrySeconds), () async {
          try {
            await attach();
          } catch (_) {
            /* 保留草稿，继续尝试发现现有内核。 */
          }
          if (epoch == _epoch && _subscribed && !_disposed) {
            unawaited(_listen(epoch));
          }
        });
        _retrySeconds = (_retrySeconds * 2).clamp(1, 10);
      }
    }
  }

  Future<void> _event(String type, Map<String, dynamic> value) async {
    switch (type) {
      case 'snapshot':
        _status(value);
        // 内核为配置源，重新订阅时读取完整配置及当前版本。
        await refreshConfiguration();
        await refreshLogs();
        for (final id in _operations.keys.toList()) {
          try {
            _operation(
              (await _request('GET', 'operations/$id'))['data']
                  as Map<String, dynamic>,
            );
          } on KernelApiException catch (e) {
            if (e.code == 'OPERATION_NOT_FOUND') {
              _operations.remove(id);
            } else {
              rethrow;
            }
          }
        }
      case 'status':
        _status(value);
        return;
      case 'configuration':
        _metadata(value);
        if (configurationChanged) await refreshConfiguration();
      case 'log':
        _log(value);
        _notifyLogs();
        return;
      case 'operation':
        _operation(value);
    }
    _notify();
  }

  void _operation(Map<String, dynamic> value) {
    final operation = DiagnosticOperation.fromJson(value);
    final old = _operations[operation.id];
    if (old != null && old.finished && !operation.finished) return;
    _operations[operation.id] = operation;
    if (_operations.length > 128) _operations.remove(_operations.keys.first);
  }

  Future<int> _apply(
    ProxyProfile profile,
    String resources,
    int expected,
  ) async {
    final validation = profile.validate(baseDirectory: directory.path);
    if (validation != null) throw StateError(validation);
    await connect(profile, resources);
    for (final c in profile.connections) {
      if (c.values['password']!.isNotEmpty) _secrets.add(c.values['password']!);
    }
    final result = await _request(
      'PUT',
      'config',
      body: profile.runtimeConfiguration,
      expectedRevision: expected,
    );
    appliedProfile = ProxyProfile.fromKernel(
      Map<String, dynamic>.from(result['data'] as Map<String, dynamic>),
      javaPath: _javaPath,
      jarPath: _jarPath,
    );
    configurationRevision = result['revision'] as int;
    configurationChanged =
        _instanceChanged || revision != configurationRevision;
    _status((await _request('GET', 'status'))['data'] as Map<String, dynamic>);
    return result['revision'] as int;
  }

  Future<int> apply(
    ProxyProfile profile,
    String resources, {
    int? expectedRevision,
  }) => _operate(
    () => _apply(profile, resources, expectedRevision ?? configurationRevision),
  );
  Future<int?> start(
    ProxyProfile profile,
    String resources, {
    bool applyDraft = true,
    int? expectedRevision,
  }) => _operate(() async {
    await connect(profile, resources);
    int? appliedRevision;
    if (applyDraft) {
      appliedRevision = await _apply(
        profile,
        resources,
        expectedRevision ?? configurationRevision,
      );
    }
    _status(
      (await _request('POST', 'proxy/start'))['data'] as Map<String, dynamic>,
    );
    return appliedRevision;
  });
  Future<void> restart() => _operate(() async {
    _status(
      (await _request('POST', 'proxy/restart'))['data'] as Map<String, dynamic>,
    );
  });
  Future<void> stop() => _operate(() async {
    _status(
      (await _request('POST', 'proxy/stop'))['data'] as Map<String, dynamic>,
    );
  });
  Future<String> requestTun(TunEngine engine) => _operate(() async {
    final result = await _request(
      'POST',
      'tun/request',
      body: {'engine': engine.name},
    );
    tunState = 'authorizing';
    tunError = '';
    tunEngine = engine;
    _notify();
    return (result['data'] as Map<String, dynamic>)['ticket'] as String;
  });
  Future<void> stopTun() => _operate(() async {
    _status(
      (await _request('POST', 'tun/stop'))['data'] as Map<String, dynamic>,
    );
  });

  /// 原生退出通知必须等当前操作完成后再撤销授权，不受普通按钮的忙碌拒绝策略影响。
  Future<void> cancelTunAuthorization() async {
    while (busy && !_disposed) {
      await _operationDone!.future;
    }
    if (!_disposed && tunState == 'authorizing') await stopTun();
  }

  Future<void> waitTunStopped() => _operate(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      _status(
        (await _request('GET', 'status'))['data'] as Map<String, dynamic>,
      );
      if (tunState == 'off') return;
      if (tunState == 'failed') throw StateError('虚拟网卡停止失败：$tunError');
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('等待虚拟网卡停止超时，请检查状态后重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
  Future<int> selectConnection(String id, {int? expectedRevision}) =>
      _operate(() async {
        final result = await _request(
          'PUT',
          'routing/default',
          body: {'profileId': id},
          expectedRevision: expectedRevision ?? configurationRevision,
        );
        await refreshConfiguration();
        _status(
          (await _request('GET', 'status'))['data'] as Map<String, dynamic>,
        );
        return result['revision'] as int;
      });
  Future<int> setRoutingMode(String mode, {int? expectedRevision}) =>
      _operate(() async {
        final result = await _request(
          'PUT',
          'routing/mode',
          body: {'mode': mode},
          expectedRevision: expectedRevision ?? configurationRevision,
        );
        await refreshConfiguration();
        _status(
          (await _request('GET', 'status'))['data'] as Map<String, dynamic>,
        );
        return result['revision'] as int;
      });

  Future<void> startOverview(String kind) => _operate(() async {
    if (!{'latency', 'websites', 'exit-ip'}.contains(kind)) {
      throw StateError('未知检测类型');
    }
    if (!connected || !running) throw StateError('请先开启服务');
    if (overviewBusy(kind)) return;
    final generation = networkGeneration;
    final instance = kernelGeneration;
    _overviewIds.remove(kind);
    _overviewStarting.add(kind);
    _notify();
    try {
      final value =
          (await _request('POST', 'overview/$kind'))['data']
              as Map<String, dynamic>;
      final operation = DiagnosticOperation.fromJson(value);
      if (!connected ||
          !running ||
          instance != kernelGeneration ||
          generation != networkGeneration ||
          operation.context['generation'] != networkGeneration) {
        return;
      }
      _operation(value);
      _overviewIds[kind] = operation.id;
    } finally {
      _overviewStarting.remove(kind);
      _notify();
    }
  });

  Future<void> disconnect() => _operate(() async {
    _status(
      (await _request(
            'POST',
            'profiles/$defaultConnectionId/disconnect',
          ))['data']
          as Map<String, dynamic>,
    );
  });
  Future<int> routeTarget(
    String target,
    String route, {
    int? expectedRevision,
  }) => _operate(() async {
    final result = await _request(
      'PUT',
      'routing/targets',
      body: {'target': target, 'route': route},
      expectedRevision: expectedRevision ?? configurationRevision,
    );
    await refreshConfiguration();
    _status((await _request('GET', 'status'))['data'] as Map<String, dynamic>);
    return result['revision'] as int;
  });
  Future<void> validateConfiguration(ProxyProfile profile) =>
      _operate(() async {
        for (final c in profile.connections) {
          if (c.values['password']!.isNotEmpty) {
            _secrets.add(c.values['password']!);
          }
        }
        await _request(
          'POST',
          'config/validate',
          body: profile.runtimeConfiguration,
        );
      });

  Future<Map<String, dynamic>> exportRouting() async =>
      (await _request('GET', 'routing/export'))['data'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> previewRouting(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) async =>
      (await _request(
            'POST',
            'routing/preview',
            body: {'document': document, 'strategy': strategy},
            expectedRevision: revision,
          ))['data']
          as Map<String, dynamic>;

  Future<int> importRouting(
    Map<String, dynamic> document,
    String strategy,
    int revision,
  ) => _operate(() async {
    final result = await _request(
      'POST',
      'routing/import',
      body: {'document': document, 'strategy': strategy},
      expectedRevision: revision,
    );
    await refreshConfiguration();
    return result['revision'] as int;
  });

  Future<Map<String, dynamic>> exportConnections(
    List<String> ids,
    bool includePassword,
  ) async =>
      (await _request(
            'POST',
            'profiles/export',
            body: {'ids': ids, 'includePassword': includePassword},
          ))['data']
          as Map<String, dynamic>;

  Future<int> updateDirectRules(String rules, {int? expectedRevision}) =>
      _operate(() async {
        final result = await _request(
          'PUT',
          'routing/direct-rules',
          body: {'rules': rules},
          expectedRevision: expectedRevision ?? configurationRevision,
        );
        await refreshConfiguration();
        return result['revision'] as int;
      });

  Future<void> validateDirectRules(String rules) => _operate(() async {
    await _request('POST', 'routing/validate', body: {'rules': rules});
  });

  Future<String> resolveRoute(String target) => _operate(() async {
    final value =
        (await _request(
              'POST',
              'routing/resolve',
              body: {'target': target},
            ))['data']
            as Map<String, dynamic>;
    _operation(value);
    return value['id'] as String;
  });

  Future<void> diagnose(String target, {String? profileId}) =>
      _operate(() async {
        final path = profileId == null
            ? 'routing/resolve'
            : 'profiles/$profileId/tests';
        _operation(
          (await _request('POST', path, body: {'target': target}))['data']
              as Map<String, dynamic>,
        );
      });
  Future<void> cancelOperation(String id) => _operate(() async {
    _operation(
      (await _request('DELETE', 'operations/$id'))['data']
          as Map<String, dynamic>,
    );
  });
  Future<T> _operate<T>(Future<T> Function() action) async {
    if (busy) throw StateError('正在处理上一项操作');
    final done = Completer<void>();
    _operationDone = done;
    busy = true;
    error = '';
    _notify();
    try {
      return await action();
    } catch (e) {
      error = redact(e.toString().replaceFirst('Bad state: ', ''));
      addLog('ERROR $error');
      rethrow;
    } finally {
      busy = false;
      _operationDone = null;
      if (!done.isCompleted) done.complete();
      _notify();
    }
  }

  Future<void> shutdown() => _operate(() async {
    unsubscribe();
    // 内核退出会移除发现文件，此时不能继续请求缓存中的旧地址。
    if (await endpointFile.exists()) {
      try {
        // 发现地址和令牌已校验时，即使状态 JSON 损坏，也允许显式退出内核。
        if (!canShutdown) await attach();
        if (canShutdown) await _request('POST', 'kernel/shutdown');
      } catch (e) {
        if (e is! SocketException && e is! HttpException) rethrow;
        // 请求期间内核也可能完成退出；仍有发现文件时不能把断线当作退出成功。
        if (await endpointFile.exists()) {
          throw StateError('无法连接内核管理接口，尚不能确认内核已退出，请稍后重试');
        }
      }
    }
    unsubscribe();
    connected = running = false;
    connection = 'idle';
    for (var i = 0; i < 60 && await endpointFile.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await endpointFile.exists()) {
      throw StateError('等待内核退出超时，请检查运行日志后重试');
    }
    _base = null;
    _token = '';
    _lastEventId = '';
    tunnels = const [];
  });
  @override
  void dispose() {
    _disposed = true;
    final done = _operationDone;
    if (done != null && !done.isCompleted) done.complete();
    unsubscribe();
    _api.dispose();
    logChanges.dispose();
    super.dispose();
  }
}
