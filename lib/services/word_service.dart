import 'dart:convert';

import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/dict_service.dart';
import 'package:toneup_read/services/translate_service.dart';

/// 点词查询：命中 `word_cache` 直接返回存储的 JSON 字符串；
/// 未命中先走 `DictService`（结构化词卡），字典失败再回落整词翻译
/// （`{"kind":"text","text":...}`），两者都失败抛原错误。
class WordService {
  final DbService _db;
  final DictService _dict;
  final TranslateService _translate;
  WordService(this._db, this._dict, this._translate);

  static const _failTtlMs = 60000;
  final Map<String, int> _failedAt = {};

  Future<String> lookup(String word, {String mode = 'en2zh'}) async {
    final lemma = word.toLowerCase().trim();
    final key = '$lemma@$mode';
    final exist = await _db.select('SELECT result FROM word_cache WHERE word = ? AND mode = ?', [lemma, mode]);
    final cached = exist.isEmpty ? null : exist.first['result'] as String?;
    if (cached != null && cached.trim().isNotEmpty) return cached;

    final now = DateTime.now().millisecondsSinceEpoch;
    final failedAt = _failedAt[key];
    // 失败冷却窗口内不再打接口（沿用既有行为：返回空串，调用方提示重试）。
    if (failedAt != null && now - failedAt < _failTtlMs) return '';

    Object? dictErr;
    Map<String, dynamic>? card;
    try {
      card = await _dict.lookupCombined(word);
    } catch (e) {
      dictErr = e;
    }
    if (card != null) {
      final result = jsonEncode(card);
      _failedAt.remove(key);
      await _save(lemma, mode, result);
      return result;
    }

    // 字典未命中/挂了：回落整词翻译。
    String? zh;
    Object? transErr;
    try {
      zh = await _translate.translate(word, from: 'en', to: 'zh');
    } catch (e) {
      transErr = e;
    }
    final t = (zh ?? '').trim();
    if (t.isNotEmpty && t != word.trim()) {
      _failedAt.remove(key);
      final result = jsonEncode({'kind': 'text', 'text': t});
      await _save(lemma, mode, result);
      return result;
    }
    _failedAt[key] = now;
    // 两者都失败：抛原错误（字典错误优先，更贴近根因）。
    // ignore: only_throw_errors
    throw dictErr ?? transErr ?? StateError('查词失败');
  }

  Future<void> _save(String lemma, String mode, String result) {
    return _db.execute('INSERT OR REPLACE INTO word_cache (word, mode, result, at, lemma) VALUES (?,?,?,?,?)',
        [lemma, mode, result, DateTime.now().millisecondsSinceEpoch, lemma]);
  }
}
