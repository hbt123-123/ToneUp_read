import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/vocab_service.dart';

import 'fake_db.dart';

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Future<AppConfigService> _cfg() async {
  // FLUTTER_TEST 下 Keystore 不可用，gateway_key 走明文 prefs 兜底（AGENTS.md 记载的约定）。
  SharedPreferences.setMockInitialValues({'gateway_key': 'test-key'});
  final c = AppConfigService();
  await c.init();
  return c;
}

class _LogDb extends FakeDb {
  final execs = <(String, List<Object?>?)>[];

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {
    execs.add((sql, params));
  }
}

class _SentenceDb extends FakeDb {
  _SentenceDb(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('vocab_sentence')) return rows;
    return [];
  }
}

/// 只喂 word_cache 的假库：organize 会按批读取，这里忽略 LIMIT/OFFSET 全部返回。
class _WordsDb extends FakeDb {
  _WordsDb(this.words);
  final List<String> words;

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (!sql.contains('FROM word_cache')) return [];
    return [
      for (final w in words) <String, dynamic>{'word': w, 'mode': 'en2zh', 'result': null}
    ];
  }
}

/// 记录 structured 透传的 model，用于断言理解型任务确实用了分析模型。
class _SpyLlm extends LlmService {
  _SpyLlm() : super(HttpService(), AppConfigService());
  String? lastModel;

  @override
  Future<dynamic> structured(String system, String user, {String? model, double temperature = 0.3}) async {
    lastModel = model;
    return {
      'translation': '译文',
      'chunks': [],
      'grammar': [],
      'keywords': [],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LlmService model 参数', () {
    test('显式传 model：请求体透传给网关（总结/长难句用分析模型）', () async {
      final cfg = await _cfg();
      Map<String, dynamic>? body;
      final llm = LlmService(
        HttpService(client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _ok({'choices': [{'message': {'content': '总结结果'}}]});
        })),
        cfg,
      );

      final out = await llm.chat('sys', 'user text', model: AppConfigService.defaultGatewayAnalysisModel, temperature: 0.3);

      expect(out, '总结结果');
      expect(body!['model'], AppConfigService.defaultGatewayAnalysisModel);
      expect(AppConfigService.defaultGatewayAnalysisModel, 'Qwen/Qwen3-8B');
    });

    test('不传 model：沿用配置的默认翻译模型（混元 MT）', () async {
      final cfg = await _cfg();
      Map<String, dynamic>? body;
      final llm = LlmService(
        HttpService(client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _ok({'choices': [{'message': {'content': '译文'}}]});
        })),
        cfg,
      );

      await llm.chat('sys', 'hello');

      expect(body!['model'], 'tencent/Hunyuan-MT-7B', reason: '翻译路径不受分析模型影响');
    });

    test('clipArticle：超长正文优先在段落边界截断（总结 prompt 的取材上限）', () {
      final long = '${List.filled(10, 'a' * 100).join('\n')}\n${'b' * 20000}';
      final clipped = LlmService.clipArticle(long, limit: 500);
      expect(clipped.length, lessThan(500));
      expect(clipped.contains('\n'), isTrue, reason: '应在段落边界断开而不是半句话');
    });
  });

  group('VocabService.organize（分批整理）', () {
    test('每批 ≤20 词、用分析模型、同名主题合并', () async {
      final bodies = <Map<String, dynamic>>[];
      final llm = LlmService(
        HttpService(client: MockClient((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _ok({
            'choices': [
              {
                'message': {'content': '{"groups":[{"theme":"学习","items":[{"word":"x"}]}]}'}
              }
            ]
          });
        })),
        await _cfg(),
      );
      final svc = VocabService(_WordsDb([for (var i = 0; i < 25; i++) 'w$i']), llm);

      final res = await svc.organize();

      expect(bodies, hasLength(2), reason: '25 个词应拆成 20 + 5 两批');
      expect(
        bodies.every((b) => b['model'] == AppConfigService.defaultGatewayAnalysisModel),
        isTrue,
        reason: '整理必须走分析模型，翻译模型不遵守 JSON 指令',
      );
      final groups = res['groups'] as List;
      expect(groups, hasLength(1), reason: '两批的同名主题应合并成一组');
      expect((groups.first['items'] as List), hasLength(2));
    });
  });

  group('VocabService.analyzeSentence', () {
    test('句子拆解走分析模型', () async {
      final llm = _SpyLlm();
      await VocabService(FakeDb(), llm).analyzeSentence('He gave up smoking last year.');
      expect(llm.lastModel, AppConfigService.defaultGatewayAnalysisModel,
          reason: '混元 MT 是翻译模型，不遵守 JSON 指令，拆解会退化成散文');
    });
  });

  group('DbService.saveAiSummary', () {
    test('UPDATE articles SET ai_summary；id<=0 不写库', () async {
      final db = _LogDb();
      await db.saveAiSummary(7, '第一行主旨\n· 要点\n难度：B2');
      expect(db.execs, hasLength(1));
      expect(db.execs.first.$1, contains('ai_summary'));
      expect(db.execs.first.$1, contains('UPDATE articles'));
      expect(db.execs.first.$2, ['第一行主旨\n· 要点\n难度：B2', 7]);

      await db.saveAiSummary(0, 'nope');
      expect(db.execs, hasLength(1), reason: '非法 id 不产生 SQL');
    });
  });

  group('VocabService.getSentenceAnalysis（句子面板的缓存读取）', () {
    final analysis = {
      'translation': '整句翻译',
      'chunks': [{'text': 'look forward to', 'type': 'phrase', 'note': '期待'}],
      'grammar': [{'point': '动名词作宾语', 'explain': 'to 后接 ing'}],
      'keywords': [{'word': 'eager', 'pos': 'adj', 'zh': '渴望的'}],
    };

    test('命中缓存 → 返回结构化 Map', () async {
      final db = _SentenceDb([
        {'analysis': jsonEncode(analysis)},
      ]);
      final svc = VocabService(db, LlmService(HttpService(), await _cfg()));
      final r = await svc.getSentenceAnalysis('some sentence');
      expect(r, isNotNull);
      expect(r!['translation'], '整句翻译');
      expect((r['chunks'] as List).first['note'], '期待');
    });

    test('无缓存 / 空字段 / 坏 JSON → null（继续走网关）', () async {
      final svc = VocabService(_SentenceDb([]), LlmService(HttpService(), await _cfg()));
      expect(await svc.getSentenceAnalysis('not saved'), isNull);

      final emptyDb = _SentenceDb([
        {'analysis': null},
      ]);
      final svc2 = VocabService(emptyDb, LlmService(HttpService(), await _cfg()));
      expect(await svc2.getSentenceAnalysis('x'), isNull);

      final badDb = _SentenceDb([
        {'analysis': 'not-json'},
      ]);
      final svc3 = VocabService(badDb, LlmService(HttpService(), await _cfg()));
      expect(await svc3.getSentenceAnalysis('x'), isNull);
    });
  });
}
