import 'dart:math';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/http_service.dart';

/// 网关词典查询：并发打 `/dict`（ECDICT 中英释义/音标/词形/考试标签）
/// 与 `/en/`（英文释义 + 发音音频），合成一份**冻结 shape** 的结构化词卡，
/// 供 `word_cache` 存储、阅读器词卡与词汇页解析共用：
///
/// ```json
/// {"kind":"dict","word":"hello","found":true,
///  "phonetic":"hә'lәu","audio":"https://...mp3","zh":"interj. 喂, 嘿",
///  "senses":[{"pos":"interj","definition":"interj. 喂, 嘿","en":"n. an expression of greeting"}],
///  "exchange":"s:hellos","tags":["zk","gk"],
///  "collins":3,"oxford":1,"bnc":2319,"frq":2238,
///  "suggestions":[{"word":"...","phonetic":"...","translation":"..."}]}
/// ```
class DictService {
  DictService(this._http, this._cfg);

  final HttpService _http;
  final AppConfigService _cfg;

  /// 单条词卡的义项上限，避免超长词典把词卡撑爆。
  static const int _maxSenses = 8;

  /// 并发查 `/dict` 与 `/en/<word>`；单个失败容忍（另一个照常出结果），
  /// 两个都失败时把首个错误原样抛出。
  Future<Map<String, dynamic>> lookupCombined(String word) async {
    final w = word.trim();
    final key = _cfg.gatewayKey.trim();
    if (key.isEmpty) {
      throw const AppException('llmKey', '本应用未内置翻译网关密钥，无法查词');
    }
    final base = _cfg.gatewayBase;
    final headers = {'Authorization': 'Bearer $key'};
    final enc = Uri.encodeComponent(w);

    Map<String, dynamic>? dict;
    Object? dictErr;
    dynamic en;
    Object? enErr;
    await Future.wait([
      () async {
        try {
          final v = await _http.getJsonAny('$base/dict?word=$enc', headers: headers);
          dict = v is Map ? Map<String, dynamic>.from(v) : null;
        } catch (e) {
          dictErr = e;
        }
      }(),
      () async {
        try {
          en = await _http.getJsonAny('$base/en/$enc', headers: headers);
        } catch (e) {
          enErr = e;
        }
      }(),
    ]);
    if (dict == null && en == null) {
      // 两个都挂：抛原错误（优先 /dict，它是主数据源）。
      // ignore: only_throw_errors
      throw dictErr ?? enErr ?? const AppException('dictEmpty', '词典没有返回内容');
    }

    final d = dict;
    final entry = (d != null && d['entry'] is Map) ? Map<String, dynamic>.from(d['entry'] as Map) : null;
    final parsedEn = _parseEn(en);

    final zhLines = _lines(entry?['translation']);
    final enDictLines = _lines(entry?['definition']);
    final enApiDefs = parsedEn?.defs ?? const <String>[];
    final enPos = parsedEn?.posList ?? const <String>[];
    final entryPos = '${entry?['pos'] ?? ''}'.trim();

    final senses = <Map<String, dynamic>>[];
    final total = max(max(zhLines.length, enDictLines.length), enApiDefs.length);
    for (var i = 0; i < total && senses.length < _maxSenses; i++) {
      final zh = i < zhLines.length ? zhLines[i] : '';
      // 英文侧：/dict 的 definition 优先，其次 /en 的英文定义。
      final enLine = i < enDictLines.length
          ? enDictLines[i]
          : (i < enApiDefs.length ? enApiDefs[i] : '');
      final definition = zh.isNotEmpty ? zh : enLine;
      if (definition.isEmpty) continue;
      senses.add({
        'pos': _posFor(zh, i, entryPos, enPos),
        'definition': definition,
        'en': enLine,
      });
    }

    final suggestions = <Map<String, dynamic>>[];
    final rawSug = d?['suggestions'];
    if (rawSug is List) {
      for (final s in rawSug.take(10)) {
        if (s is! Map) continue;
        suggestions.add({
          'word': '${s['word'] ?? ''}',
          'phonetic': '${s['phonetic'] ?? ''}',
          'translation': '${s['translation'] ?? ''}',
        });
      }
    }

    final found = d != null
        ? d['found'] == true
        : senses.isNotEmpty || (parsedEn?.word.isNotEmpty ?? false);

    return <String, dynamic>{
      'kind': 'dict',
      'word': (entry?['word'] ?? parsedEn?.word ?? w).toString(),
      'found': found,
      'phonetic': (entry?['phonetic'] ?? parsedEn?.phonetic ?? '').toString(),
      'audio': parsedEn?.audio ?? '',
      'zh': zhLines.join('\n'),
      'senses': senses,
      'exchange': '${entry?['exchange'] ?? ''}',
      'tags': _splitTags(entry?['tag']),
      'collins': entry?['collins'] is num ? (entry!['collins'] as num).toInt() : null,
      'oxford': entry?['oxford'] is num ? (entry!['oxford'] as num).toInt() : null,
      'bnc': entry?['bnc'] is num ? (entry!['bnc'] as num).toInt() : null,
      'frq': entry?['frq'] is num ? (entry!['frq'] as num).toInt() : null,
      'suggestions': suggestions,
    };
  }

  /// /en 的两种形态都解析：dictionaryapi.dev 的对象数组，或 ecdict-fallback 的单对象。
  _EnData? _parseEn(dynamic raw) {
    if (raw == null) return null;
    final out = _EnData();
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        _readEnEntry(item, out);
      }
      return out;
    }
    if (raw is Map) {
      // ecdict-fallback：{source, word, phonetic, meanings:[{definition}]}
      out.word = '${raw['word'] ?? ''}';
      out.phonetic = '${raw['phonetic'] ?? ''}';
      final meanings = raw['meanings'];
      if (meanings is List) {
        for (final m in meanings) {
          if (m is! Map) continue;
          final pos = '${m['partOfSpeech'] ?? m['pos'] ?? ''}';
          final defs = m['definitions'];
          if (defs is List) {
            for (final x in defs) {
              if (x is! Map) continue;
              final t = '${x['definition'] ?? ''}';
              if (t.isEmpty) continue;
              out.defs.add(t);
              out.posList.add(pos);
            }
          } else {
            final t = '${m['definition'] ?? ''}';
            if (t.isEmpty) continue;
            out.defs.add(t);
            out.posList.add(pos);
          }
        }
      }
      return out;
    }
    return null;
  }

  void _readEnEntry(Map item, _EnData out) {
    if (out.word.isEmpty) out.word = '${item['word'] ?? ''}';
    final phonetics = item['phonetics'];
    if (phonetics is List) {
      for (final p in phonetics) {
        if (p is! Map) continue;
        if (out.phonetic.isEmpty) {
          final t = '${p['text'] ?? ''}';
          if (t.isNotEmpty) out.phonetic = t;
        }
        if (out.audio.isEmpty) {
          final a = '${p['audio'] ?? ''}';
          if (a.isNotEmpty) out.audio = a;
        }
      }
    }
    final meanings = item['meanings'];
    if (meanings is! List) return;
    for (final m in meanings) {
      if (m is! Map) continue;
      final pos = '${m['partOfSpeech'] ?? m['pos'] ?? ''}';
      final defs = m['definitions'];
      if (defs is! List) continue;
      for (final x in defs) {
        if (x is! Map) continue;
        final t = '${x['definition'] ?? ''}';
        if (t.isEmpty) continue;
        out.defs.add(t);
        out.posList.add(pos);
      }
    }
  }

  /// 义项词性：中文行自带前缀（`interj. 喂`）> /dict 的 pos > /en 的 partOfSpeech。
  String _posFor(String zhLine, int i, String entryPos, List<String> enPos) {
    final m = RegExp(r'^([A-Za-z]{1,12}\.?)\s+').firstMatch(zhLine.trim());
    if (m != null) {
      final raw = m.group(1)!;
      return raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
    }
    if (entryPos.isNotEmpty) return entryPos;
    if (i < enPos.length && enPos[i].isNotEmpty) return enPos[i];
    return '';
  }

  List<String> _lines(Object? raw) {
    final s = '${raw ?? ''}';
    if (s.trim().isEmpty) return const [];
    return s
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  List<String> _splitTags(Object? raw) {
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return const [];
    return s.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  }
}

class _EnData {
  String word = '';
  String phonetic = '';
  String audio = '';
  final List<String> defs = [];
  final List<String> posList = [];
}
