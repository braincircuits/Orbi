enum TunEngine {
  outline('Outline SDK'),
  tun2socks('xjasonlyu/tun2socks');

  const TunEngine(this.label);
  final String label;

  static TunEngine parse(String value) => values.firstWhere(
    (engine) => engine.name == value,
    orElse: () => throw FormatException('TUN 转发组件无效：$value'),
  );
}
