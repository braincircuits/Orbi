/// 测试夹具提供当前内核协议要求的流量字段，不读取真实配置。
Map<String, dynamic> trafficFixture({
  String session = 'traffic-test',
  int time = 1000,
  bool history = true,
}) {
  final sample = <String, dynamic>{
    'sampledAt': time,
    'sentBytes': 36800000,
    'receivedBytes': 1240000000,
    'sendBytesPerSecond': 128000.0,
    'receiveBytesPerSecond': 2460000.0,
  };
  return {
    'sessionId': session,
    'startedAt': 1,
    ...sample,
    if (history)
      'history': [
        for (var i = 60; i >= 0; i--) {...sample, 'sampledAt': time - i * 1000},
      ],
  };
}
