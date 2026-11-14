import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toneup_read/features/favorites/screens/favorites_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/vocab_service.dart';

import 'fake_db.dart';

class _Op {
  _Op(this.sql, this.params);
  final String sql;
  final List<Object?>? params;
}

/// 内存版 vocab 三表 + word_cache：只实现 VocabService 用到的几条 SQL，
/// 同时把 select/execute 的语句与参数记录下来供断言（打桩模式同 remote_article_service_test）。
class _VocabTestDb extends FakeDb {
  final List<_Op> executed = [];
  final List<_Op> selected = [];
  final List<Map<String, dynamic>> vocabHead = [];
  final List<Map<String, dynamic>> vocabOcc = [];
  final List<Map<String, dynamic>> wordCache = [];
  final List<Map<String, dynamic>> sentences = [];

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    selected.add(_Op(sql, params));
    if (sql.startsWith('SELECT head FROM vocab_head')) {
      return [for (final r in vocabHead) {'head': r['head']}];
    }
    if (sql.startsWith('SELECT head, kind, firstSeen, lastSeen, occCount, family FROM vocab_head')) {
      return [for (final r in vocabHead) Map<String, dynamic>.of(r)];
    }
    if (sql.contains('FROM vocab_occ GROUP BY lemma')) {
      final byLemma = <String, List<Map<String, dynamic>>>{};
      for (final r in vocabOcc) {
        byLemma.putIfAbsent('${r['lemma']}', () => []).add(r);
      }
      return [
        for (final e in byLemma.entries)
          {
            'lemma': e.key,
            'c': e.value.map((r) => r['articleGuid']).toSet().length,
            'm': e.value.fold<int>(0, (mx, r) {
              final at = (r['at'] as int?) ?? 0;
              return at > mx ? at : mx;
            }),
            'sentence': e.value.first['sentence'],
          }
      ];
    }
    if (sql.startsWith('SELECT word, lemma, result FROM word_cache')) {
      final p = params ?? const <Object?>[];
      final half = p.length ~/ 2;
      return [
        for (final r in wordCache)
          if (p.sublist(0, half).contains(r['word']) || p.sublist(half).contains(r['lemma'])) Map<String, dynamic>.of(r)
      ];
    }
    if (sql.startsWith('SELECT word, lemma, at FROM word_cache')) {
      return [
        for (final r in wordCache)
          if (r['mode'] == 'en2zh' || r['mode'] == 'en2en') {'word': r['word'], 'lemma': r['lemma'], 'at': r['at']}
      ];
    }
    if (sql.contains('FROM vocab_sentence ORDER BY at DESC')) {
      final rows = [...sentences]..sort((a, b) => ((b['at'] ?? 0) as int).compareTo((a['at'] ?? 0) as int));
      return [for (final r in rows) Map<String, dynamic>.of(r)];
    }
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {
    executed.add(_Op(sql, params));
    final p = params ?? const <Object?>[];
    if (sql.startsWith('UPDATE vocab_sentence SET translation')) {
      for (final r in sentences) {
        if (r['sentence'] == p[1]) r['translation'] = p[0];
      }
    } else if (sql.startsWith('DELETE FROM vocab_sentence WHERE id = ?')) {
      sentences.removeWhere((r) => r['id'] == p[0]);
    }
  }
}

/// mode 不用 en2zh/en2en：避开 syncHeadsFromCache 的自动沉淀，保持种子可控。
Map<String, dynamic> _wcRow(String word, String resultJson) =>
    {'word': word, 'lemma': word, 'mode': 'fixture', 'result': resultJson};

Map<String, dynamic> _dictResult(String word, String phonetic, String zh) => jsonEncode({
      'kind': 'dict',
      'word': word,
      'phonetic': phonetic,
      'zh': zh,
      'senses': [
        {'pos': 'n', 'definition': zh, 'en': 'fruit'},
      ],
    });

VocabService _svc(_VocabTestDb db) => VocabService(db, LlmService(HttpService(), AppConfigService()));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('VocabService（收藏简化后）', () {
    test('getSentences 透传 id 与 translation，按 at 倒序', () async {
      final db = _VocabTestDb();
      db.sentences.addAll([
        {
          'id': 7,
          'sentence': 'The sky is blue.',
          'articleGuid': 'g1',
          'articleTitle': 'Sky',
          'sourceLabel': '',
          'paraIndex': 0,
          'tokIndex': 0,
          'at': 100,
          'analysis': null,
          'translation': '天空是蓝的。',
        },
        {'id': 3, 'sentence': 'Hello world.', 'at': 200, 'translation': null},
      ]);
      final list = await _svc(db).getSentences();
      expect(list.length, 2);
      expect(list[0]['id'], 3);
      expect(list[0]['translation'], isNull);
      expect(list[1]['id'], 7);
      expect(list[1]['translation'], '天空是蓝的。');
    });

    test('saveTranslation 写 UPDATE（译文在前、原句在后），空译文不写', () async {
      final db = _VocabTestDb();
      db.sentences.add({'id': 1, 'sentence': 'Hello world.', 'at': 1});
      final svc = _svc(db);

      await svc.saveTranslation('Hello world.', '  你好，世界。 ');
      final ups = db.executed.where((e) => e.sql.startsWith('UPDATE vocab_sentence SET translation')).toList();
      expect(ups, hasLength(1));
      expect(ups.single.params, ['你好，世界。', 'Hello world.']);
      expect(db.sentences.first['translation'], '你好，世界。');

      await svc.saveTranslation('Hello world.', '   ');
      expect(db.executed.where((e) => e.sql.startsWith('UPDATE vocab_sentence SET translation')), hasLength(1));
    });

    test('removeSentence 按 id 删除', () async {
      final db = _VocabTestDb();
      db.sentences.add({'id': 42, 'sentence': 'Bye.', 'at': 1});
      await _svc(db).removeSentence(42);
      final dels = db.executed.where((e) => e.sql.startsWith('DELETE FROM vocab_sentence WHERE id = ?')).toList();
      expect(dels, hasLength(1));
      expect(dels.single.params, [42]);
      expect(db.sentences, isEmpty);
    });

    test('getHeads 从 word_cache JSON 提取 phonetic 与 zh', () async {
      final db = _VocabTestDb();
      db.vocabHead.add({'head': 'apple', 'kind': 'word', 'firstSeen': 1, 'lastSeen': 2, 'occCount': 1});
      db.vocabOcc.add({'lemma': 'apple', 'articleGuid': 'a1', 'sentence': 'I eat an apple.', 'at': 5});
      db.wordCache.add(_wcRow('apple', _dictResult('apple', "'æpl", 'n. 苹果')));

      final heads = await _svc(db).getHeads();
      expect(heads.single['head'], 'apple');
      expect(heads.single['phonetic'], "'æpl");
      expect(heads.single['zh'], 'n. 苹果');
      expect(heads.single['sourceCount'], 1);
      expect(heads.single['latestSentence'], 'I eat an apple.');
    });

    test('getHeads 查询不再涉及 fsrs 字段（FSRS 已下线）', () async {
      final db = _VocabTestDb();
      db.vocabHead.add({'head': 'apple', 'kind': 'word', 'firstSeen': 1, 'lastSeen': 2, 'occCount': 1});
      await _svc(db).getHeads();
      final headSqls = db.selected.where((e) => e.sql.contains('FROM vocab_head')).map((e) => e.sql).toList();
      expect(headSqls, isNotEmpty);
      for (final s in headSqls) {
        expect(s.contains('fsrs'), isFalse, reason: '不应再查询 fsrs 字段: $s');
      }
    });
  });

  group('收藏页（widget）', () {
    _VocabTestDb _seed() {
      final db = _VocabTestDb();
      db.vocabHead.addAll([
        {'head': 'apple', 'kind': 'word', 'firstSeen': 1, 'lastSeen': 2, 'occCount': 1},
        {'head': 'orange', 'kind': 'word', 'firstSeen': 1, 'lastSeen': 3, 'occCount': 2},
      ]);
      db.vocabOcc.addAll([
        {'lemma': 'apple', 'articleGuid': 'a1', 'sentence': 'I eat an apple every day.', 'at': 5},
        {'lemma': 'orange', 'articleGuid': 'a1', 'sentence': 'Orange juice please.', 'at': 6},
      ]);
      db.wordCache.addAll([
        _wcRow('apple', _dictResult('apple', "'æpl", 'n. 苹果')),
        _wcRow('orange', _dictResult('orange', "'ɒrɪndʒ", 'n. 橙子')),
      ]);
      db.sentences.add({
        'id': 9,
        'sentence': 'The weather is nice today.',
        'articleGuid': 'g1',
        'articleTitle': 'Weather',
        'sourceLabel': 'News',
        'paraIndex': 0,
        'tokIndex': 0,
        'at': 100,
        'analysis': null,
        'translation': null,
      });
      return db;
    }

    Future<void> _openFavorites(WidgetTester tester, _VocabTestDb db) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [dbProvider.overrideWithValue(db)],
        child: const MaterialApp(home: FavoritesScreen()),
      ));
      // 首帧后 post-frame 回调发起加载；两帧让 setState 重建落地。
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
    }

    testWidgets('词卡有发音按钮；搜索可过滤词列表', (tester) async {
      final db = _seed();
      await _openFavorites(tester, db);

      expect(find.text('apple'), findsOneWidget);
      expect(find.text('orange'), findsOneWidget);
      // 发音按钮（GoIcon 'tts' → volume_up_outlined），每个词卡一个；不点（TTS 走平台通道）。
      expect(find.byIcon(Icons.volume_up_outlined), findsNWidgets(2));

      await tester.enterText(find.byType(TextField), 'app');
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('apple'), findsOneWidget);
      expect(find.text('orange'), findsNothing);
      expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
    });

    testWidgets('搜索无结果时显示未找到空态', (tester) async {
      final db = _seed();
      await _openFavorites(tester, db);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('apple'), findsNothing);
      expect(find.text('未找到「zzzz」'), findsOneWidget);
    });

    testWidgets('句子卡有删除按钮；确认后删除并回空态', (tester) async {
      final db = _seed();
      await _openFavorites(tester, db);

      await tester.tap(find.textContaining('句子 1'));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.textContaining('The weather is nice today.'), findsOneWidget);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300)); // 确认框入场动画
      expect(find.text('从收藏里移除这句句子？'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await tester.pump(const Duration(milliseconds: 60));

      expect(db.sentences, isEmpty);
      final dels = db.executed.where((e) => e.sql.startsWith('DELETE FROM vocab_sentence WHERE id = ?')).toList();
      expect(dels, hasLength(1));
      expect(dels.single.params, [9]);
      expect(find.textContaining('The weather is nice today.'), findsNothing);
      expect(find.text('还没有收藏的句子'), findsOneWidget);
    });
  });
}
