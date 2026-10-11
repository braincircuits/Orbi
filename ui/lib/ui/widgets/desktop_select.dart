import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../desktop_theme.dart';

/// 统一桌面选择框，仅组合官方菜单组件和应用主题。
class DesktopSelect<T> extends StatelessWidget {
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.clamp(0.0, DesktopDesign.menuWidth);
      final theme = Theme.of(context);
      return DropdownMenu<T>(
        key: ValueKey((
          value,
          options.where((option) => option.$1 == value).firstOrNull?.$2,
        )),
        enabled: onSelected != null,
        initialSelection: value,
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
            size: 18,
          ),
        ),
        menuStyle: theme.dropdownMenuTheme.menuStyle!.copyWith(
          maximumSize: WidgetStatePropertyAll(Size(width, 320)),
        ),
        dropdownMenuEntries: [
          for (final option in options)
            DropdownMenuEntry(
              value: option.$1,
              label: option.$2,
              labelWidget: Text(
                option.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailingIcon: option.$1 == value
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: theme.colorScheme.primary,
                    )
                  : const SizedBox(width: 16),
            ),
        ],
        onSelected: (next) {
          if (next != null) onSelected?.call(next);
        },
      );
    },
  );
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
