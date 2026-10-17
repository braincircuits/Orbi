import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/models/kernel_status.dart';
import 'package:network_ui/ui/desktop_theme.dart';
import 'package:network_ui/ui/pages/tunnels_page.dart';
import 'package:network_ui/view_models/proxy_view_model.dart';

import 'history_records_test.dart' show LargeHistoryKernel;
import 'view_model_test.dart' show TestDesktop;

class _Kernel extends LargeHistoryKernel {
  int historyReads = 0;
  @override
  Future<AccessRecordPage> accessHistory({
    String target = '',
    bool failedOnly = false,
    String order = 'recent',
    bool ascending = false,
    int? beforeValue,
    String afterHost = '',
  }) {
    historyReads++;
    return super.accessHistory(
      target: target,
      failedOnly: failedOnly,
      order: order,
      ascending: ascending,
      beforeValue: beforeValue,
      afterHost: afterHost,
    );
  }
}

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('深处隧道切回仅构建可见行 $platform $brightness', (tester) async {
        tester.view.physicalSize = const Size(1280, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final kernel = _Kernel()
          ..connected = true
          ..tunnels = List.generate(
            5000,
            (i) => TunnelStatus(
              id: '$i',
              target: 'record-$i.example:443',
              source: '127.0.0.1:12345',
              route: 'direct',
              state: 'active',
              profileName: '',
              protocol: 'tcp',
              originalProtocol: 'tcp',
              createdAt: DateTime(2026, 10, 17).add(Duration(seconds: i)),
            ),
          );
        final model = ProxyViewModel(
          proxy: kernel,
          native: TestDesktop(Directory.systemTemp),
        )..loading = false;
        addTearDown(model.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: desktopTheme(brightness).copyWith(platform: platform),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(
                    brightness == Brightness.dark ? 2 : 1,
                  ),
                ),
                child: Scaffold(body: TunnelsPage(model: model)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        ScrollPosition position(String key) => tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(PageStorageKey(key)),
                matching: find.byType(Scrollable),
              ),
            )
            .position;

        var rowsBuilt = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (element.widget is MenuAnchor) rowsBuilt++;
          previous?.call(element, builtOnce);
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);

        final live = position('tunnels');
        live.jumpTo(200000);
        await tester.pumpAndSettle();
        final target = find.textContaining('.example:443').first;
        final visibleTarget = tester.widget<Text>(target).data!;
        final firstY = tester.getTopLeft(target).dy;
        expect(live.pixels, 200000);
        expect(kernel.historyReads, 0);

        for (var i = 0; i < 2; i++) {
          await tester.tap(find.text('访问记录'));
          await tester.pumpAndSettle();
          expect(kernel.historyReads, 1);
          if (i == 0) {
            await tester.enterText(
              find.byKey(const ValueKey('access-search')),
              '保留未提交的搜索',
            );
          } else {
            expect(position('access-records').pixels, 120000);
            expect(find.text('保留未提交的搜索'), findsOneWidget);
          }
          position('access-records').jumpTo(120000);
          await tester.pumpAndSettle();
          // 后台隧道快照仍可更新，但隐藏的实时列表不应随推送重建。
          rowsBuilt = 0;
          kernel.tunnels = kernel.tunnels.skip(1).toList();
          kernel.notifyListeners();
          await tester.pump();
          expect(rowsBuilt, 0);
          rowsBuilt = 0;
          await tester.tap(find.text('实时隧道'));
          await tester.pump();
          // 限制真实构建数量，不能仅检查最终留在屏幕上的少量行。
          expect(rowsBuilt, lessThan(60));
          expect(position('tunnels'), same(live));
          expect(position('tunnels').pixels, 200000);
          expect(tester.getTopLeft(find.text(visibleTarget)).dy, firstY);
          final text = find.text(visibleTarget);
          final row = find
              .ancestor(of: text, matching: find.byType(Container))
              .first;
          final textBounds = tester.getRect(text);
          final rowBounds = tester.getRect(row);
          expect(textBounds.top, greaterThanOrEqualTo(rowBounds.top));
          expect(textBounds.bottom, lessThanOrEqualTo(rowBounds.bottom));
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.getTopLeft(find.text(visibleTarget)).dy, firstY);
          expect(tester.takeException(), isNull);
        }

        // 切回时读取最新快照，缩短的列表应自然收敛到有效滚动范围。
        await tester.tap(find.text('访问记录'));
        await tester.pumpAndSettle();
        kernel.tunnels = kernel.tunnels.take(3).toList();
        kernel.notifyListeners();
        await tester.tap(find.text('实时隧道'));
        await tester.pumpAndSettle();
        expect(find.text('共 3 条 · 活跃 3 · 等待 0'), findsOneWidget);
        expect(position('tunnels').pixels, 0);
        expect(find.text('record-2.example:443'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
