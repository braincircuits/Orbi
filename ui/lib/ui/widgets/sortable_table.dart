import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../desktop_theme.dart';

/// 固定表头、按需构建行；窄窗口横向滚动，不改变列结构。
class SortableTable extends StatefulWidget {
  const SortableTable({
    super.key,
    required this.columns,
    required this.widths,
    required this.sortColumn,
    required this.ascending,
    required this.onSort,
    required this.rowCount,
    required this.rowKey,
    required this.cells,
    required this.empty,
    this.controller,
    this.listKey,
  });

  final List<String> columns;
  // 第一列占用剩余宽度，其余列使用指定宽度。
  final List<double> widths;
  final int sortColumn;
  final bool ascending;
  final ValueChanged<int>? onSort;
  final int rowCount;
  final String Function(int) rowKey;
  final List<Widget> Function(int) cells;
  final Widget empty;
  final ScrollController? controller;
  final Key? listKey;

  @override
  State<SortableTable> createState() => _SortableTableState();
}

class _SortableTableState extends State<SortableTable> {
  final horizontal = ScrollController();
  final vertical = ScrollController();

  @override
  void dispose() {
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  Widget _row(List<Widget> cells) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          if (i == 0)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: cells[i],
              ),
            )
          else
            SizedBox(width: widget.widths[i], child: cells[i]),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indices = {
      for (var i = 0; i < widget.rowCount; i++) widget.rowKey(i): i,
    };
    final scroll = widget.controller ?? vertical;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(DesktopDesign.panelRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          controller: horizontal,
          thumbVisibility: true,
          notificationPredicate: (notice) =>
              notice.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(
                constraints.maxWidth,
                widget.widths.reduce((a, b) => a + b) + 32,
              ),
              height: constraints.maxHeight,
              child: Column(
                children: [
                  ColoredBox(
                    color: scheme.surfaceContainerLow,
                    child: _row([
                      for (var i = 0; i < widget.columns.length; i++)
                        Semantics(
                          header: true,
                          value: widget.sortColumn == i
                              ? (widget.ascending ? '升序' : '降序')
                              : '未排序',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: widget.onSort == null
                                    ? null
                                    : () => widget.onSort!(i),
                                style: TextButton.styleFrom(
                                  alignment: Alignment.centerLeft,
                                  foregroundColor: widget.sortColumn == i
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 8,
                                  ),
                                  overlayColor: scheme.onSurface,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.columns[i],
                                        maxLines: 1,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      widget.sortColumn == i
                                          ? (widget.ascending
                                                ? Icons.arrow_upward
                                                : Icons.arrow_downward)
                                          : Icons.unfold_more,
                                      size: 14,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: widget.rowCount == 0
                        ? widget.empty
                        : Scrollbar(
                            controller: scroll,
                            child: SelectionArea(
                              child: ListView.builder(
                                key: widget.listKey,
                                controller: scroll,
                                itemCount: widget.rowCount,
                                findChildIndexCallback: (key) =>
                                    key is ValueKey<String>
                                    ? indices[key.value]
                                    : null,
                                itemBuilder: (context, index) => Container(
                                  key: ValueKey(widget.rowKey(index)),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: scheme.outlineVariant,
                                      ),
                                    ),
                                  ),
                                  child: _row(widget.cells(index)),
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单元格保留完整文本供悬停查看和选择复制。
class TableText extends StatelessWidget {
  const TableText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}
