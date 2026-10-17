import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../desktop_theme.dart';

/// 统一桌面选择框，仅组合官方菜单组件和应用主题。
class DesktopSelect<T> extends StatefulWidget {
  const DesktopSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final T? value;
  final List<(T, String)> options;
  final ValueChanged<T?>? onSelected;

  @override
  State<DesktopSelect<T>> createState() => _DesktopSelectState<T>();
}

class _DesktopSelectState<T> extends State<DesktopSelect<T>> {
  List<(T, String)> _options = [];
  List<DropdownMenuEntry<T>> _entries = [];
  T? _value;
  Color? _selectionColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // DropdownMenu 会在选项列表对象变化时重建菜单项，导致刷新期间的点击丢失。
    // 仅在选项、选中值或勾选颜色变化时更新列表，保留正在进行的鼠标和键盘操作。
    if (!listEquals(_options, widget.options) ||
        _value != widget.value ||
        _selectionColor != theme.colorScheme.primary) {
      _options = List.of(widget.options);
      _value = widget.value;
      _selectionColor = theme.colorScheme.primary;
      _entries = [
        for (final option in _options)
          DropdownMenuEntry(
            value: option.$1,
            label: option.$2,
            labelWidget: Text(
              option.$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailingIcon: option.$1 == widget.value
                ? Icon(Icons.check, size: 16, color: _selectionColor)
                : const SizedBox(width: 16),
          ),
      ];
    }
    return DropdownMenu<T>(
      key: ValueKey((
        widget.value,
        _options.where((option) => option.$1 == widget.value).firstOrNull?.$2,
      )),
      enabled: widget.onSelected != null,
      initialSelection: widget.value,
      expandedInsets: EdgeInsets.zero,
      selectOnly: true,
      requestFocusOnTap: true,
      enableSearch: false,
      alignmentOffset: const Offset(0, 4),
      decorationBuilder: (_, controller) => InputDecoration(
        suffixIcon: Icon(
          controller.isOpen
              ? Icons.keyboard_arrow_up
              : Icons.keyboard_arrow_down,
          size: DesktopDesign.actionIconSize,
        ),
      ),
      // 菜单自行适配视口，不用 LayoutBuilder 阻断弹窗的固有尺寸测量。
      menuStyle: theme.dropdownMenuTheme.menuStyle!.copyWith(
        maximumSize: const WidgetStatePropertyAll(
          Size(DesktopDesign.menuWidth, 320),
        ),
      ),
      dropdownMenuEntries: _entries,
      onSelected: (next) {
        if (next != null) widget.onSelected?.call(next);
      },
    );
  }
}

@Preview(name: '桌面下拉菜单 · 浅色', size: Size(640, 320))
@Preview(name: '桌面下拉菜单 · 深色', size: Size(640, 320), brightness: Brightness.dark)
Widget desktopSelectPreview() => Builder(
  builder: (context) => Theme(
    data: desktopTheme(Theme.of(context).brightness),
    child: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: DesktopSelect<String>(
          value: 'http2',
          options: const [
            ('http3', 'HTTP/3 · QUIC / UDP'),
            ('http2', 'HTTP/2 · TLS / TCP'),
          ],
          onSelected: (_) {},
        ),
      ),
    ),
  ),
);
