import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/app.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/widgets/bottom_nav.dart';

import 'fake_db.dart';

void main() {
  testWidgets('app builds（底部导航 3 个 Tab：首页/收藏/我的）', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(FakeDb())],
      child: const MyApp(),
    ));
    expect(find.byType(MyApp), findsOneWidget);

    // 云端化后固定 3 Tab：首页 / 收藏 / 我的（原「词汇」「句子」合并为收藏）。
    expect(find.byType(BottomNav), findsOneWidget);
    for (final label in const ['首页', '收藏', '我的']) {
      expect(
        find.descendant(of: find.byType(BottomNav), matching: find.text(label)),
        findsOneWidget,
        reason: '底部导航应包含「$label」Tab',
      );
    }
  });
}
