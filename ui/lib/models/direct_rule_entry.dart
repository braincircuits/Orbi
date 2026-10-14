import 'dart:io';

/// 仅解释规则原文用于展示和定位；匹配与格式校验仍由内核负责。
class DirectRuleEntry {
  const DirectRuleEntry(this.line, this.target, this.note, this.group);
  final int line;
  final String target, note, group;

  static List<DirectRuleEntry> parse(String text) {
    var group = '';
    final entries = <DirectRuleEntry>[];
    for (final (index, source) in text.split('\n').indexed) {
      final value = source.trim();
      if (value.startsWith('#')) {
        group = value.substring(1).trim();
        continue;
      }
      final marker = value.indexOf('#');
      final target = (marker < 0 ? value : value.substring(0, marker)).trim();
      if (target.isNotEmpty) {
        entries.add(
          DirectRuleEntry(
            index,
            target,
            marker < 0 ? '' : value.substring(marker + 1).trim(),
            group,
          ),
        );
      }
    }
    return entries;
  }

  String get scope => target.contains('/')
      ? 'IP 网段'
      : InternetAddress.tryParse(target) != null
      ? '仅此 IP'
      : '域名及所有子域名';

  static String hostKey(String target) =>
      InternetAddress.tryParse(target)?.address ??
      target.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  /// 管理接口的目标使用 host:port，规则实际作用于目标的所有端口。
  static String authority(String host) =>
      '${host.contains(':') ? '[$host]' : host}:443';

  static String replace(String text, int line, String? replacement) {
    final lines = text.split('\n');
    if (replacement == null) {
      lines.removeAt(line);
    } else {
      lines[line] = replacement;
    }
    return lines.join('\n');
  }
}
