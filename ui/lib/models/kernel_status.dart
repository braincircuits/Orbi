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

/// 每次启动拥有独立会话；只保留实时速率，分钟趋势从持久化接口读取。
class TrafficSnapshot {
  const TrafficSnapshot({
    required this.sessionId,
    required this.startedAt,
    required this.current,
  });
  final String sessionId;
  final int startedAt;
  final TrafficSample current;

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
    if (sameSession &&
        current.sampledAt == previous!.current.sampledAt &&
        current.sentBytes == previous.current.sentBytes &&
        current.receivedBytes == previous.current.receivedBytes &&
        current.sendBytesPerSecond == previous.current.sendBytesPerSecond &&
        current.receiveBytesPerSecond ==
            previous.current.receiveBytesPerSecond) {
      return previous;
    }
    return TrafficSnapshot(
      sessionId: session,
      startedAt: value['startedAt'] as int,
      current: current,
    );
  }
}

/// 每个完整域名或 IP 的累计连接统计，不保留逐连接明细。
class AccessRecord {
  AccessRecord.fromJson(Map<String, dynamic> value)
    : host = value['host'] as String,
      connectionCount = value['connectionCount'] as int,
      lastAccessAt = value['lastAccessAt'] as int,
      lastFailureAt = value['lastFailureAt'] as int;
  final String host;
  final int connectionCount, lastAccessAt, lastFailureAt;
}

class AccessRecordPage {
  AccessRecordPage.fromJson(Map<String, dynamic> value)
    : items = List.unmodifiable(
        (value['items'] as List).map(
          (item) => AccessRecord.fromJson(item as Map<String, dynamic>),
        ),
      ),
      hasMore = value['hasMore'] as bool,
      nextValue = value['nextValue'] as int,
      nextHost = value['nextHost'] as String;
  final List<AccessRecord> items;
  final bool hasMore;
  final int nextValue;
  final String nextHost;
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
  // 连续推送可能重新解析出内容相同的对象，按快照内容比较可避免无效刷新。
  Object get _identity => (
    id,
    target,
    source,
    route,
    state,
    profileName,
    protocol,
    originalProtocol,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      other is TunnelStatus && _identity == other._identity;
  @override
  int get hashCode => _identity.hashCode;
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
