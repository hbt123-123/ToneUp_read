import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/screens/vocab_screen.dart';
import 'package:toneup_read/services/db_service.dart';

/// 统计各表查询次数，不触碰 sqflite。
class CountingDb extends DbService {
  int vocabQueries = 0;

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('vocab_head') || sql.contains('vocab_occ') || sql.contains('vocab_sentence')) vocabQueries++;
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {}

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> clearAll() async {}
}

/// 词汇页带地球动效（GoGlobe 里AnimationController..repeat()，105 秒一轮，永不停），
/// `pumpAndSettle` 会一直等到超时。这里统一用固定时长 pump 代替。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(); // 触发 build
  await tester.pump(const Duration(milliseconds: 600)); // 越过 400ms 防抖 + 异步查询
}

void main() {
  testWidgets('词汇变更信号会让常驻的词汇页重新加载', (tester) async {
    final db = CountingDb();
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(db)],
      child: const MaterialApp(home: VocabScreen()),
    ));
    await _settle(tester);

    // 词汇页只在自己是当前 Tab 时才监听信号，先切到该Tab 还原真实场景。
    final container = ProviderScope.containerOf(tester.element(find.byType(VocabScreen)));
    container.read(tabIndexProvider.notifier).set(1); // 词汇现在是 1 号 Tab
    await _settle(tester);

    final before = db.vocabQueries;
    expect(before, greaterThan(0), reason: '首次进入应已查询词汇');

    // 模拟「文章页点词 / 复习评分」触发信号
    container.read(vocabRevisionProvider.notifier).bump();
    await _settle(tester);

    expect(db.vocabQueries, greaterThan(before), reason: '收到词汇变更后应重新查询，否则新增生词/待复习数不更新');
  });

  testWidgets('隐藏的词汇页不响应变更信号，切回时才补刷', (tester) async {
    final db = CountingDb();
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(db)],
      child: const MaterialApp(home: VocabScreen()),
    ));
    await _settle(tester);

    final container = ProviderScope.containerOf(tester.element(find.byType(VocabScreen)));
    // 词汇页是第 2 个 Tab（index 1）。单测里它被直接挂载，等价于「不在该 Tab 上」。
    expect(container.read(tabIndexProvider), isNot(1));

    final hiddenBefore = db.vocabQueries;
    container.read(vocabRevisionProvider.notifier).bump();
    await _settle(tester);
    expect(db.vocabQueries, hiddenBefore, reason: '页面不可见时不该全量重载，否则阅读中每点一个词都拖慢一次');

    // 切到该 Tab 后应补一次刷新，不能留着旧数据
    container.read(tabIndexProvider.notifier).set(1);
    await _settle(tester);
    expect(db.vocabQueries, greaterThan(hiddenBefore), reason: '切回本页时应补刷隐藏期间的变化');
  });
}
