import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/screens/vocab_screen.dart';
import 'package:toneup_read/widgets/go_ui.dart';

import 'fake_db.dart';

/// 生词导出（M4 决策 11）：复制文本必须是**半角逗号 + 半角空格**拼接的英文 head，
/// 顺序与 `VocabService.getHeads()`（= 本假库返回顺序）一致；空词表直接 SnackBar 提示。
///
/// - 页面有常驻动画（GoPage 辉光），**不用 pumpAndSettle**，固定时长 pump。
/// - 剪贴板用 `SystemChannels.platform` 的 mock handler 捕获 `Clipboard.setData`。
/// - SharePlus 分支不测（原生 share sheet 无法稳定 mock）。

const _heads = <Map<String, dynamic>>[
  {'head': 'zebra', 'kind': 'word', 'occCount': 2},
  {'head': 'apple', 'kind': 'word', 'occCount': 1},
  {'head': 'mango', 'kind': 'word', 'occCount': 1},
];

class _VocabDb extends FakeDb {
  /// 生词（getHeads 的 ORDER BY 顺序由这里给定，导出断言直接依赖它）。
  final List<Map<String, dynamic>> heads;

  _VocabDb(this.heads);

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    // getHeads 主查询：ORDER BY lastSeen DESC
    if (sql.contains('FROM vocab_head ORDER BY lastSeen DESC')) return heads;
    // getHeads 回填 zh：word_cache 分批查询（syncHeadsFromCache 的那条是
    // "WHERE word IS NOT NULL AND mode IN"，不含本子串，不会误命中）。
    if (sql.contains('FROM word_cache WHERE word IN')) {
      return [
        for (final h in heads)
          {'word': h['head'], 'lemma': h['head'], 'result': '{"kind":"text","text":"中文释义"}'},
      ];
    }
    // syncHeadsFromCache 的 vocab_head 全量读、dueCount 的 COUNT 都回空即可：
    // 前者空 → 不删不插；后者 rows.isEmpty → 0。
    return [];
  }
}

/// 按 appbar 实际结构定位导出按钮：`GoIconBtn(icon: 'export')`。
final _exportBtn = find.byWidgetPredicate((w) => w is GoIconBtn && w.icon == 'export');

/// 捕获 Clipboard.setData 的文本（同时吞掉 HapticFeedback 等同通道调用）。
List<String> _mockClipboard() {
  final captured = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final args = call.arguments as Map;
      captured.add('${args['text']}');
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return captured;
}

Future<void> _pumpVocab(WidgetTester tester, _VocabDb db) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [dbProvider.overrideWithValue(db)],
    child: const MaterialApp(home: VocabScreen()),
  ));
  await tester.pump(); // 首帧：postFrameCallback 里发起 _load
  await tester.pump(const Duration(milliseconds: 20)); // syncHeads/getHeads/dueCount 完成
}

void main() {
  testWidgets('复制文本：半角逗号分隔、只含英文 head、顺序与 getHeads 一致', (tester) async {
    final captured = _mockClipboard();
    await _pumpVocab(tester, _VocabDb(_heads));

    expect(find.text('zebra'), findsOneWidget, reason: '词条应已渲染');
    expect(_exportBtn, findsOneWidget);

    await tester.tap(_exportBtn);
    await tester.pump(); // 弹层开始入场
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('导出生词'), findsOneWidget, reason: '导出弹层应打开');
    expect(find.text('复制文本'), findsOneWidget);

    await tester.tap(find.text('复制文本'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(captured, hasLength(1), reason: '应恰好捕获一次 Clipboard.setData');
    final txt = captured.single;
    expect(txt, 'zebra, apple, mango', reason: '半角逗号+空格、getHeads 顺序、仅英文 head');
    expect(txt, isNot(contains('，')), reason: '禁用全角逗号');
    expect(RegExp(r'^[a-zA-Z]+(, [a-zA-Z]+)*$').hasMatch(txt), isTrue, reason: '只含英文词条与分隔符');
    expect(find.text('已复制 3 个词'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // SnackBar 的 4s 自动消失计时器要跑完，否则测试结束时报 pending timer。
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('空词表点导出：只给 SnackBar，不弹层不碰剪贴板', (tester) async {
    final captured = _mockClipboard();
    await _pumpVocab(tester, _VocabDb(const []));

    expect(find.text('还没有收藏的词汇'), findsOneWidget, reason: '空态应先渲染出来');
    expect(_exportBtn, findsOneWidget, reason: '导出按钮不随词表置灰');

    await tester.tap(_exportBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('暂无生词可导出'), findsOneWidget);
    expect(find.text('导出生词'), findsNothing, reason: '空词表不应打开弹层');
    expect(find.text('复制文本'), findsNothing);
    expect(captured, isEmpty, reason: '不应触碰剪贴板');
    expect(tester.takeException(), isNull);

    // 同上：跑掉 SnackBar 的自动消失计时器。
    await tester.pump(const Duration(seconds: 5));
  });
}
