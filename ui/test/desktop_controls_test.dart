import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/widgets/desktop_select.dart';

void main() {
  testWidgets('普通输入、搜索、密码、选择框与按钮共享高度且支持文字缩放', (tester) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        Widget field(String name, {Widget? prefix, Widget? suffix}) => SizedBox(
          width: 160,
          child: TextField(
            key: ValueKey(name),
            decoration: InputDecoration(
              hintText: name,
              prefixIcon: prefix,
              suffixIcon: suffix,
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Column(
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        field('普通输入'),
                        field('搜索', prefix: const Icon(Icons.search, size: 17)),
                        field(
                          '密码',
                          suffix: IconButton(
                            onPressed: () {},
                            icon: const Icon(Icons.visibility_outlined),
                          ),
                        ),
                        SizedBox(
                          width: 160,
                          child: DesktopSelect<String>(
                            key: const ValueKey('选择框'),
                            value: 'http2',
                            options: const [
                              ('http2', 'HTTP/2'),
                              ('http3', 'HTTP/3'),
                            ],
                            onSelected: (_) {},
                          ),
                        ),
                        FilledButton(
                          key: const ValueKey('主按钮'),
                          onPressed: () {},
                          child: const Text('保存'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('次按钮'),
                          onPressed: () {},
                          child: const Text('校验'),
                        ),
                        TextButton(
                          key: const ValueKey('文字按钮'),
                          onPressed: () {},
                          child: const Text('还原'),
                        ),
                        SegmentedButton<bool>(
                          key: const ValueKey('分段按钮'),
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: true, label: Text('卡片')),
                            ButtonSegment(value: false, label: Text('列表')),
                          ],
                          selected: const {true},
                          onSelectionChanged: (_) {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(
                      height: 160,
                      child: TextField(
                        key: ValueKey('多行编辑'),
                        expands: true,
                        maxLines: null,
                        decoration: InputDecoration(
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final name in [
          '普通输入',
          '搜索',
          '密码',
          '选择框',
          '主按钮',
          '次按钮',
          '文字按钮',
          '分段按钮',
        ]) {
          final height = tester.getSize(find.byKey(ValueKey(name))).height;
          expect(
            height,
            scale == 1
                ? DesktopDesign.controlHeight
                : greaterThanOrEqualTo(DesktopDesign.controlHeight),
            reason: '$name / $brightness / $scale',
          );
        }
        for (final name in ['普通输入', '搜索', '密码', '选择框']) {
          final editor = find
              .descendant(
                of: find.byKey(ValueKey(name)),
                matching: find.byType(EditableText),
              )
              .first;
          final border = InputDecorator.containerOf(tester.element(editor))!;
          final expectedHeight = InputDecorator.containerOf(
            tester.element(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('普通输入')),
                    matching: find.byType(EditableText),
                  )
                  .first,
            ),
          )!.size.height;
          expect(
            border.size.height,
            closeTo(expectedHeight, .01),
            reason: '可见边框：$name / $brightness / $scale',
          );
          if (scale == 1) {
            expect(border.size.height, DesktopDesign.controlHeight);
          }
        }
        expect(tester.getSize(find.byKey(const ValueKey('多行编辑'))).height, 160);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
