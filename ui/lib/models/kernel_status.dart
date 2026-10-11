/// 内核每秒产生的业务流量采样，速率单位为字节／秒。
class TrafficSample {
  const TrafficSample({
    required this.sampledAt,
    required this.sentBytes,
    required this.receivedBytes,
    required this.sendBytesPerSecond,
    required this.receiveBytesPerSecond,
  });
  factory TrafficSample.fromJson(Map<String, dynamic> value) => TrafficSample(
    sampledAt: value['sampledAt'] as int,
    sentBytes: value['sentBytes'] as int,
    receivedBytes: value['receivedBytes'] as int,
    sendBytesPerSecond: (value['sendBytesPerSecond'] as num).toDouble(),
    receiveBytesPerSecond: (value['receiveBytesPerSecond'] as num).toDouble(),
  );
  final int sampledAt, sentBytes, receivedBytes;
  final double sendBytesPerSecond, receiveBytesPerSecond;
}

/// 每次启动拥有独立会话；初始快照补齐历史，后续状态只合并最新采样。
class TrafficSnapshot {
  const TrafficSnapshot({
    required this.sessionId,
    required this.startedAt,
    required this.current,
    required this.history,
  });
  final String sessionId;
  final int startedAt;
  final TrafficSample current;
  final List<TrafficSample> history;

  static TrafficSnapshot merge(
    TrafficSnapshot? previous,
    Map<String, dynamic> value,
  ) {
    final session = value['sessionId'] as String;
    final current = TrafficSample.fromJson(value);
    final sameSession = previous?.sessionId == session;
    if (sameSession && current.sampledAt < previous!.current.sampledAt) {
      return previous;
    }
    final samples = <int, TrafficSample>{};
    final history = value['history'] as List?;
    final source = history != null
        ? history.map(
            (item) => TrafficSample.fromJson(item as Map<String, dynamic>),
          )
        : sameSession
        ? previous!.history
        : const <TrafficSample>[];
    for (final sample in source) {
      if (sample.sampledAt >= current.sampledAt - 300000 &&
          sample.sampledAt <= current.sampledAt) {
        samples[sample.sampledAt] = sample;
      }
    }
    if (session.isNotEmpty) samples[current.sampledAt] = current;
    final ordered = samples.values.toList()
      ..sort((a, b) => a.sampledAt.compareTo(b.sampledAt));
    return TrafficSnapshot(
      sessionId: session,
      startedAt: value['startedAt'] as int,
      current: current,
      history: List.unmodifiable(
        ordered.skip(ordered.length > 301 ? ordered.length - 301 : 0),
      ),
    );
  }
}

/// 访问记录按一次本地 HTTP 请求或 CONNECT 隧道计数，不表示网页请求成功。
class AccessRecord {
  AccessRecord.fromJson(Map<String, dynamic> value)
    : id = value['id'] as int,
      createdAt = DateTime.fromMillisecondsSinceEpoch(
        value['createdAt'] as int,
      ),
      target = value['target'] as String,
      source = value['source'] as String,
      method = value['method'] as String,
      route = value['route'] as String,
      protocol = value['protocol'] as String,
      profileName = value['profileName'] as String,
      state = value['state'] as String;
  final int id;
  final DateTime createdAt;
  final String target, source, method, route, protocol, profileName, state;
  String get originalProtocolLabel => method == 'CONNECT-UDP' ? 'UDP' : 'TCP';
  String get protocolLabel => _protocolLabel(protocol);
  String get stateLabel => switch (state) {
    'connected' => '已建立连接',
    'failed' => '连接失败',
    'cancelled' => '已取消',
    _ => '未完成',
  };
  String get routeLabel => switch (route) {
    'direct' => '直连',
    'proxy' => '代理',
    _ => '待确定',
  };
}

class AccessRecordPage {
  AccessRecordPage.fromJson(Map<String, dynamic> value)
    : items = List.unmodifiable(
        (value['items'] as List).map(
          (item) => AccessRecord.fromJson(item as Map<String, dynamic>),
        ),
      ),
      nextBeforeId = value['nextBeforeId'] as int;
  final List<AccessRecord> items;
  final int nextBeforeId;
}

class TrafficRecordPage {
  TrafficRecordPage.fromJson(Map<String, dynamic> value) {
    final rows = (value['items'] as List).cast<Map<String, dynamic>>();
    nextBeforeId = value['nextBeforeId'] as int;
    if (rows.isNotEmpty) {
      final newest = rows.first;
      final visible = rows
          .where(
            (row) =>
                row['sessionId'] == newest['sessionId'] &&
                (row['sampledAt'] as int) >=
                    (newest['sampledAt'] as int) - 300000,
          )
          .toList();
      if (visible.length < rows.length) {
        nextBeforeId = visible.last['id'] as int;
      }
      // 一张图只显示一个启动会话，避免把两次启动的采样连成一条曲线。
      traffic = TrafficSnapshot.merge(null, {
        ...newest,
        'history': visible.reversed.toList(),
      });
    }
  }
  TrafficSnapshot? traffic;
  late int nextBeforeId;
}

/// 内核当前的业务隧道快照，包含代理流和直连连接。
class TunnelStatus {
  const TunnelStatus({
    required this.id,
    required this.target,
    required this.source,
    required this.route,
    required this.state,
    required this.profileName,
    required this.protocol,
    required this.originalProtocol,
    required this.createdAt,
  });

  factory TunnelStatus.fromJson(Map<String, dynamic> json) => TunnelStatus(
    id: json['id'] as String,
    target: json['target'] as String,
    source: json['source'] as String,
    route: json['route'] as String,
    state: json['state'] as String,
    profileName: json['profileName'] as String,
    protocol: json['protocol'] as String,
    originalProtocol: json['originalProtocol'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
  );

  final String id, target, source, route, state, profileName, protocol;
  final String originalProtocol;
  final DateTime createdAt;
  String get originalProtocolLabel => originalProtocol.toUpperCase();
  String get stateLabel => switch (state) {
    'active' => '活跃',
    'pending' => '等待连接',
    'resolving' => '解析中',
    _ => state,
  };
  String get routeLabel => switch (route) {
    'proxy' => '代理',
    'direct' => '直连',
    'resolving' => '待确定',
    _ => route,
  };
  String get protocolLabel => _protocolLabel(protocol);
}

String _protocolLabel(String protocol) => switch (protocol) {
  'http2' => 'HTTP/2',
  'http3' => 'HTTP/3',
  'tcp' => 'TCP',
  'udp' => 'UDP',
  _ => protocol,
};

class ConnectionStatus {
  const ConnectionStatus({
    required this.id,
    required this.name,
    required this.protocol,
    required this.activeTunnels,
    required this.pendingTunnels,
  });
  factory ConnectionStatus.fromJson(Map<String, dynamic> value) =>
      ConnectionStatus(
        id: value['id'] as String? ?? '',
        name: value['name'] as String? ?? '',
        protocol: value['protocol'] as String? ?? '',
        activeTunnels: value['activeTunnels'] as int? ?? 0,
        pendingTunnels: value['pendingTunnels'] as int? ?? 0,
      );
  final String id, name, protocol;
  final int activeTunnels, pendingTunnels;
}

class DiagnosticStage {
  DiagnosticStage.fromJson(Map<String, dynamic> value)
    : stage = value['stage'] as String,
      elapsedMillis = value['elapsedMillis'] as int;
  final String stage;
  final int elapsedMillis;
}

class DiagnosticResult {
  DiagnosticResult.fromJson(Map<String, dynamic> value)
    : latencyMillis = (value['latencyMillis'] as num?)?.toDouble(),
      checkedAt = DateTime.tryParse('${value['checkedAt'] ?? ''}'),
      ip = value['ip'] as String?,
      country = value['country'] as String? ?? '',
      region = value['region'] as String? ?? '',
      city = value['city'] as String? ?? '',
      provider = value['provider'] as String? ?? '',
      websites = List.unmodifiable(
        (value['websites'] as List? ?? []).map(
          (item) => WebsiteResult.fromJson(item as Map<String, dynamic>),
        ),
      ),
      profileId = value['profileId'] as String?,
      code = value['code'] as String?,
      message = value['message'] as String?,
      tunnelEstablished = value['tunnelEstablished'] == true,
      target = value['target'] as String?,
      action = value['action'] as String?,
      matchedBy = value['matchedBy'] as String?,
      resolvedAddress = value['resolvedAddress'] as String?;
  final String? profileId,
      code,
      message,
      target,
      action,
      matchedBy,
      resolvedAddress;
  final bool tunnelEstablished;
  final double? latencyMillis;
  final DateTime? checkedAt;
  final String? ip;
  final String country, region, city, provider;
  final List<WebsiteResult> websites;
}

class DiagnosticOperation {
  DiagnosticOperation.fromJson(Map<String, dynamic> value)
    : context = Map<String, dynamic>.unmodifiable(
        value['context'] as Map<String, dynamic>? ?? {},
      ),
      id = value['id'] as String,
      state = value['state'] as String,
      stage = value['stage'] as String,
      elapsedMillis = value['elapsedMillis'] as int,
      result = DiagnosticResult.fromJson(
        value['result'] as Map<String, dynamic>? ?? {},
      ),
      stages = List.unmodifiable(
        (value['stages'] as List<dynamic>? ?? []).map(
          (item) => DiagnosticStage.fromJson(item as Map<String, dynamic>),
        ),
      );
  final Map<String, dynamic> context;
  final String id, state, stage;
  final int elapsedMillis;
  final DiagnosticResult result;
  final List<DiagnosticStage> stages;
  bool get finished =>
      const {'succeeded', 'failed', 'cancelled'}.contains(state);
}

/// 网站响应耗时独立于服务端 RTT；HTTP 错误保留实际响应状态。
class WebsiteResult {
  WebsiteResult.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      state = value['state'] as String,
      latencyMillis = (value['latencyMillis'] as num?)?.toDouble(),
      httpStatus = value['httpStatus'] as int?,
      checkedAt = DateTime.tryParse('${value['checkedAt'] ?? ''}');
  final String id, state;
  final double? latencyMillis;
  final int? httpStatus;
  final DateTime? checkedAt;
  String get label => switch (state) {
    'reachable' => '可访问',
    'http_error' => 'HTTP $httpStatus',
    'timeout' => '超时',
    _ => '连接失败',
  };
}
