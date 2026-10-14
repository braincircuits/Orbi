/// 流量统一使用十进制单位，速率与坐标轴使用同一换算口径。
String formatTrafficBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 || value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2)} ${units[unit]}';
}
