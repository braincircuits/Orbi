/// 历史统计按本机日历切分；日、月边界不能用固定的 24 小时或 30 天替代。
enum TrafficPeriod {
  hour('时', '分钟', '本小时'),
  day('日', '小时', '今天'),
  month('月', '天', '本月');

  const TrafficPeriod(this.label, this.bucketLabel, this.currentLabel);
  final String label, bucketLabel, currentLabel;
}

String trafficDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String trafficTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class TrafficWindow {
  TrafficWindow(this.period, this.anchor);
  final TrafficPeriod period;
  final DateTime anchor;
  DateTime get start => switch (period) {
    // 保留夏令时回拨时重复小时的实际偏移。
    TrafficPeriod.hour => anchor.subtract(
      Duration(
        minutes: anchor.minute,
        seconds: anchor.second,
        milliseconds: anchor.millisecond,
        microseconds: anchor.microsecond,
      ),
    ),
    TrafficPeriod.day => DateTime(anchor.year, anchor.month, anchor.day),
    TrafficPeriod.month => DateTime(anchor.year, anchor.month),
  };
  DateTime get end => switch (period) {
    TrafficPeriod.hour => start.add(const Duration(hours: 1)),
    TrafficPeriod.day => DateTime(anchor.year, anchor.month, anchor.day + 1),
    TrafficPeriod.month => DateTime(anchor.year, anchor.month + 1),
  };
  List<DateTime> get boundaries {
    final result = <DateTime>[start];
    while (result.last.isBefore(end)) {
      final last = result.last;
      result.add(switch (period) {
        TrafficPeriod.hour => last.add(const Duration(minutes: 1)),
        TrafficPeriod.day => last.add(const Duration(hours: 1)),
        TrafficPeriod.month => DateTime(last.year, last.month, last.day + 1),
      });
    }
    // 少数时区按半小时调整夏令时，最后一个区间以实际日界截断。
    result[result.length - 1] = end;
    return result;
  }

  TrafficWindow shift(int amount) => TrafficWindow(period, switch (period) {
    TrafficPeriod.hour => start.add(Duration(hours: amount)),
    TrafficPeriod.day => DateTime(start.year, start.month, start.day + amount),
    TrafficPeriod.month => DateTime(start.year, start.month + amount),
  });
  String get title => switch (period) {
    TrafficPeriod.hour =>
      '${trafficDate(start)} ${trafficTime(start)} · ${start.timeZoneName}',
    TrafficPeriod.day => trafficDate(start),
    TrafficPeriod.month =>
      '${start.year}-${start.month.toString().padLeft(2, '0')}',
  };
}

class TrafficBucket {
  TrafficBucket.fromJson(Map<String, dynamic> value)
    : from = DateTime.fromMillisecondsSinceEpoch(value['from'] as int),
      to = DateTime.fromMillisecondsSinceEpoch(value['to'] as int),
      sentBytes = value['sentBytes'] as int,
      receivedBytes = value['receivedBytes'] as int,
      recordCount = value['recordCount'] as int;
  final DateTime from, to;
  final int sentBytes, receivedBytes, recordCount;
}

class TrafficSummary {
  TrafficSummary.fromJson(Map<String, dynamic> value)
    : buckets = List.unmodifiable(
        (value['buckets'] as List).map(
          (item) => TrafficBucket.fromJson(item as Map<String, dynamic>),
        ),
      ),
      sentBytes = value['sentBytes'] as int,
      receivedBytes = value['receivedBytes'] as int,
      recordCount = value['recordCount'] as int,
      latestMinuteStart = value['latestMinuteStart'] as int;
  final List<TrafficBucket> buckets;
  final int sentBytes, receivedBytes, recordCount, latestMinuteStart;
}
