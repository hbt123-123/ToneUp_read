import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/screens/mine_screen.dart';

import 'fake_db.dart';

/// 页尾固定文案（mine 页最后一段：签名 + 版本号）。
const _footer = '一潼上岸·阅读 · By 潼潼';

void main() {
  testWidgets('我的页内容超高时仍可滚动（能拖到页尾）', (tester) async {
    // 服务配置改为内置后，mine 页只剩 数据管理/关于 两段（比旧版矮了不少），
    // 视口相应大幅调矮，保证「内容超出视口」这个前置条件依旧成立。
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(FakeDb())],
      child: const MaterialApp(home: MineScreen()),
    ));
    await tester.pumpAndSettle();

    // 锚点 = 页尾签名行（数据管理 / 关于+检查更新 之后）。
    final footer = find.text(_footer);
    expect(footer, findsOneWidget);

    // 前置条件：内容（两段 + 页尾）应超出 400 高的视口。
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置条件：内容应超出视口');

    final before = tester.getTopLeft(footer).dy;

    // 拖动幅度远超可滚动距离 → 应停在页尾。
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(footer).dy, lessThan(before), reason: '页面应能向上拖动');
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
      reason: '持续上拖应滚到页尾（被边界截停）',
    );
  });
}
