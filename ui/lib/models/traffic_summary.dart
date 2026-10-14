/// 区间边界及文字由内核按其所在时区生成，客户端不再自行切分日历。
class TrafficBucket {
  TrafficBucket.fromJson(Map<String, dynamic> value)
    : from = value['from'] as int,
      to = value['to'] as int,
      sentBytes = value['sentBytes'] as int,
      receivedBytes = value['receivedBytes'] as int,
      recordCount = value['recordCount'] as int,
      label = value['label'] as String,
      shortLabel = value['shortLabel'] as String;
  final int from, to, sentBytes, receivedBytes, recordCount;
  final String label, shortLabel;
}

class TrafficSummary {
  TrafficSummary.fromJson(Map<String, dynamic> value)
    : buckets = List.unmodifiable(
        (value['buckets'] as List).map(
          (item) => TrafficBucket.fromJson(item as Map<String, dynamic>),
        ),
      ),
      from = value['from'] as int,
      to = value['to'] as int,
      zoneId = value['zoneId'] as String,
      interval = value['interval'] as String,
      sentBytes = value['sentBytes'] as int,
      receivedBytes = value['receivedBytes'] as int,
      recordCount = value['recordCount'] as int;
  final List<TrafficBucket> buckets;
  final int from, to, sentBytes, receivedBytes, recordCount;
  final String zoneId, interval;
}
