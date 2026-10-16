import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/dict_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/translate_service.dart';
import 'package:toneup_read/services/word_service.dart';

import 'fake_db.dart';

class _Db extends FakeDb {
  final List<String> writes = [];
  Object? cached;

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('FROM word_cache')) return cached == null ? [] : [<String, dynamic>{'result': cached}];
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {
    writes.add(sql);
    if (sql.contains('INSERT OR REPLACE INTO word_cache')) cached = params?[2];
  }
}

/// 结构化词卡假实现：命中设 [card]，未命中/挂了设 [error]。
class _FakeDict extends DictService {
  _FakeDict() : super(HttpService(), AppConfigService());
  int calls = 0;
  Map<String, dynamic>? card;
  Object? error;

  @override
  Future<Map<String, dynamic>> lookupCombined(String word) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    final c = card;
    if (c != null) return c;
    throw StateError('dict miss');
  }
}

class _FakeTranslate extends TranslateService {
  _FakeTranslate() : super(LlmService(HttpService(), AppConfigService()));
  int calls = 0;
  String result = '';
  Object? error;

  @override
  Future<String> translate(String text, {String from = 'en', String to = 'zh'}) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return result;
  }
}

Map<String, dynamic> _card(String word) => {
      'kind': 'dict',
      'found': true,
      'word': word,
      'phonetic': "ˈprɪvəsi",
      'senses': [
        {'pos': 'n.', 'definition': '隐私', 'en': 'the state of being private'}
      ],
    };

void main() {
  test('字典命中：缓存写入 dict JSON，再命中不发第二次请求', () async {
    final db = _Db();
    final dict = _FakeDict()..card = _card('privacy');
    final tr = _FakeTranslate()..result = '不应被用到';
    final svc = WordService(db, dict, tr);

    final out = await svc.lookup('privacy');
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    expect(decoded['kind'], 'dict');
    expect((decoded['senses'] as List).first, containsPair('definition', '隐私'));
    expect(db.cached, isA<String>(), reason: '缓存里存的必须是 JSON 字符串而不是对象');
    expect(db.cached, out);

    expect(await svc.lookup('privacy'), out, reason: '第二次直接命中缓存');
    expect(dict.calls, 1);
    expect(tr.calls, 0, reason: '字典已命中，不该再回落翻译');
    expect(db.writes.where((w) => w.contains('word_cache')).length, 1);
  });

  test('字典失败回落整词翻译：缓存写入 text JSON', () async {
    final db = _Db();
    final dict = _FakeDict()..error = StateError('dict down');
    final tr = _FakeTranslate()..result = '隐私';
    final svc = WordService(db, dict, tr);

    final out = await svc.lookup('privacy');
    expect(jsonDecode(out), {'kind': 'text', 'text': '隐私'});
    expect(db.cached, out);
    expect(dict.calls, 1);
    expect(tr.calls, 1);

    expect(await svc.lookup('privacy'), out, reason: '回落结果也进缓存');
    expect(tr.calls, 1);
  });

  test('字典与翻译都失败：抛原错误、不写缓存，并进入负缓存', () async {
    final db = _Db();
    final dict = _FakeDict()..error = StateError('dict down');
    final tr = _FakeTranslate()..error = StateError('boom');
    final svc = WordService(db, dict, tr);

    await expectLater(svc.lookup('privacy'), throwsA(isA<StateError>()));
    expect(await svc.lookup('privacy'), '', reason: '60 秒冷却窗口内直接返回空串');
    expect(dict.calls, 1, reason: '冷却期内不应重复打字典');
    expect(tr.calls, 1, reason: '冷却期内不应重复打翻译');
    expect(db.writes.where((w) => w.contains('word_cache')), isEmpty);
  });

  test('翻译返回原文视为失败，进入冷却', () async {
    final db = _Db();
    final dict = _FakeDict()..error = StateError('dict down');
    final tr = _FakeTranslate()..result = 'privacy';
    final svc = WordService(db, dict, tr);

    await expectLater(svc.lookup('privacy'), throwsA(isA<StateError>()));
    expect(db.writes.where((w) => w.contains('word_cache')), isEmpty);
  });

  test('历史遗留的空缓存会被视为未命中并重试', () async {
    final db = _Db()..cached = '';
    final dict = _FakeDict()..card = _card('privacy');
    final tr = _FakeTranslate();
    final svc = WordService(db, dict, tr);

    final out = await svc.lookup('privacy');
    expect(jsonDecode(out)['kind'], 'dict');
    expect(dict.calls, 1);
  });
}
