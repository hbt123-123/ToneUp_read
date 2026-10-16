import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/dict_service.dart';
import 'package:toneup_read/services/http_service.dart';

const String _base = 'https://gw.test';
const String _key = 'dict-key';

Map<String, String> get _jsonHeaders => {'content-type': 'application/json'};

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

/// 按源码实际读取路径注入：`init()` 读 `gateway_base` / `gateway_key`
/// （FLUTTER_TEST 下 Keystore 不可用，密钥回落到明文 `gateway_key`）。
Future<AppConfigService> _config({String gatewayKey = _key}) async {
  SharedPreferences.setMockInitialValues({
    'gateway_base': _base,
    'gateway_key': gatewayKey,
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

DictService _svc(AppConfigService cfg, http.Client client) => DictService(HttpService(client: client), cfg);

/// `/dict` 的完整响应：多行中英释义、考试标签、词频数字、建议词。
final Map<String, dynamic> _dictFull = {
  'found': true,
  'entry': {
    'word': 'hello',
    'phonetic': "hә'lәu",
    'translation': 'interj. 喂, 嘿\n招呼, 问候',
    'definition': 'a greeting expression\nan expression of greeting',
    'pos': 'int',
    'tag': 'zk  gk\tcet4',
    'exchange': 's:hellos',
    'collins': 3,
    'bnc': 2319,
    'frq': 2238,
    'oxford': 1,
  },
  'suggestions': [
    {'word': 'hell', 'phonetic': 'hel', 'translation': 'n. 地狱'},
  ],
};

/// `/en/<word>` 的 dictionaryapi.dev 形态：对象数组。
final List<Map<String, dynamic>> _enArray = [
  {
    'word': 'hello',
    'phonetics': [
      {'text': 'həˈləʊ', 'audio': 'https://cdn.test/hello.mp3'},
    ],
    'meanings': [
      {
        'partOfSpeech': 'exclamation',
        'definitions': [
          {'definition': 'used as a greeting'},
          {'definition': 'used to answer the phone'},
        ],
      },
    ],
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('并发合成 /dict + /en：音标优先 /dict、audio 取 /en、senses 中英配对、tags 切分', () async {
    final cfg = await _config();
    final reqs = <http.Request>[];
    final svc = _svc(cfg, MockClient((req) async {
      reqs.add(req);
      if (req.url.path == '/dict') return _ok(_dictFull);
      if (req.url.path == '/en/hello') return _ok(_enArray);
      return http.Response('not found', 404);
    }));

    // 前后空白会被 trim 后再拼 URL。
    final r = await svc.lookupCombined('  hello  ');

    expect(reqs.map((e) => e.url.path).toSet(), {'/dict', '/en/hello'});
    expect(reqs.where((e) => e.url.path == '/dict'), hasLength(1));
    expect(reqs.where((e) => e.url.path == '/en/hello'), hasLength(1));
    final dictReq = reqs.firstWhere((e) => e.url.path == '/dict');
    final enReq = reqs.firstWhere((e) => e.url.path == '/en/hello');
    expect(dictReq.method, 'GET');
    expect(enReq.method, 'GET');
    expect(dictReq.url.queryParameters['word'], 'hello');
    expect(dictReq.headers['Authorization'], 'Bearer $_key');
    expect(enReq.headers['Authorization'], 'Bearer $_key');

    expect(r['kind'], 'dict');
    expect(r['found'], true);
    expect(r['word'], 'hello');
    expect(r['phonetic'], "hә'lәu", reason: '音标以 /dict 的 entry 为准，忽略 /en 的 həˈləʊ');
    expect(r['audio'], 'https://cdn.test/hello.mp3', reason: '音频只能来自 /en');
    expect(r['zh'], 'interj. 喂, 嘿\n招呼, 问候');
    expect(r['exchange'], 's:hellos');
    expect(r['tags'], ['zk', 'gk', 'cet4']);
    expect(r['collins'], 3);
    expect(r['oxford'], 1);
    expect(r['bnc'], 2319);
    expect(r['frq'], 2238);

    final senses = (r['senses'] as List).cast<Map<String, dynamic>>();
    expect(senses, hasLength(2));
    expect(senses[0], {
      'pos': 'interj', // 中文行自带词性前缀
      'definition': 'interj. 喂, 嘿', // 中文侧
      'en': 'a greeting expression', // 英文侧取 /dict 的 definition
    });
    expect(senses[1], {
      'pos': 'int', // 中文行无前缀 → 回落 entry.pos
      'definition': '招呼, 问候',
      'en': 'an expression of greeting',
    });

    final sug = (r['suggestions'] as List).cast<Map<String, dynamic>>();
    expect(sug, hasLength(1));
    expect(sug[0], {'word': 'hell', 'phonetic': 'hel', 'translation': 'n. 地狱'});
  });

  test('found=false 时原样保留 suggestions，/en 空数组不补义项', () async {
    final cfg = await _config();
    final svc = _svc(cfg, MockClient((req) async {
      if (req.url.path == '/dict') {
        return _ok({
          'found': false,
          'entry': {
            'word': 'xyzzy',
            'phonetic': '',
            'translation': '',
            'definition': '',
            'pos': '',
            'tag': '',
            'exchange': '',
          },
          'suggestions': [
            {'word': 'xyster', 'phonetic': 'ˈzɪstə', 'translation': 'n. 刮齿刀'},
            {'word': 'xylophone', 'phonetic': '', 'translation': ''},
          ],
        });
      }
      return _ok(<dynamic>[]);
    }));

    final r = await svc.lookupCombined('xyzzy');

    expect(r['found'], false);
    expect(r['word'], 'xyzzy');
    expect(r['senses'], isEmpty);
    expect(r['audio'], '');
    expect(r['tags'], isEmpty);
    final sug = (r['suggestions'] as List).cast<Map<String, dynamic>>();
    expect(sug, hasLength(2));
    expect(sug[0], {'word': 'xyster', 'phonetic': 'ˈzɪstə', 'translation': 'n. 刮齿刀'});
    expect(sug[1], {'word': 'xylophone', 'phonetic': '', 'translation': ''});
  });

  test('/en 失败仍返回 /dict 结果，且 /en 不重试', () async {
    final cfg = await _config();
    final reqs = <http.Request>[];
    final svc = _svc(cfg, MockClient((req) async {
      reqs.add(req);
      if (req.url.path == '/dict') return _ok(_dictFull);
      return http.Response('gateway down', 500);
    }));

    final r = await svc.lookupCombined('hello');

    expect(r['found'], true);
    expect(r['phonetic'], "hә'lәu");
    expect(r['zh'], 'interj. 喂, 嘿\n招呼, 问候');
    expect(r['audio'], '', reason: '/en 挂了就没有音频');
    expect((r['senses'] as List), hasLength(2));
    expect(reqs.where((e) => e.url.path == '/en/hello'), hasLength(1), reason: 'RetryPolicy.none 不重试');
    expect(reqs.where((e) => e.url.path == '/dict'), hasLength(1));
  });

  test('/dict 与 /en 都失败时抛错（优先 /dict 的错误）', () async {
    final cfg = await _config();
    final reqs = <http.Request>[];
    final svc = _svc(cfg, MockClient((req) async {
      reqs.add(req);
      if (req.url.path == '/dict') return http.Response('boom', 500);
      return http.Response('nope', 404);
    }));

    await expectLater(
      svc.lookupCombined('hello'),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'http500')
          .having((e) => e.status, 'status', 500)),
    );
    expect(reqs, hasLength(2), reason: '/dict、/en 各打一次');
  });

  test('/dict 失败时用 /en 的 fallback 对象合成结果', () async {
    final cfg = await _config();
    final reqs = <http.Request>[];
    final svc = _svc(cfg, MockClient((req) async {
      reqs.add(req);
      if (req.url.path == '/dict') return http.Response('boom', 500);
      return _ok({
        'source': 'ecdict-fallback',
        'word': 'fallback',
        'phonetic': 'ˈfɔːl.bæk',
        'meanings': [
          {
            'partOfSpeech': 'noun',
            'definitions': [
              {'definition': 'a backup plan'},
            ],
          },
        ],
      });
    }));

    final r = await svc.lookupCombined('fallback');

    expect(reqs.map((e) => e.url.path).toSet(), {'/dict', '/en/fallback'});
    expect(r['found'], true, reason: '/en 有义项 → found 由 senses 推导');
    expect(r['word'], 'fallback');
    expect(r['phonetic'], 'ˈfɔːl.bæk');
    expect(r['audio'], '');
    expect(r['tags'], isEmpty);
    expect(r['collins'], isNull);
    expect(r['suggestions'], isEmpty);
    final senses = (r['senses'] as List).cast<Map<String, dynamic>>();
    expect(senses, hasLength(1));
    expect(senses[0], {'pos': 'noun', 'definition': 'a backup plan', 'en': 'a backup plan'});
  });

  test('未配置网关密钥时抛 llmKey 且不发任何请求', () async {
    final cfg = await _config(gatewayKey: '');
    final reqs = <http.Request>[];
    final svc = _svc(cfg, MockClient((req) async {
      reqs.add(req);
      return _ok(<dynamic>[]);
    }));

    await expectLater(
      svc.lookupCombined('hello'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmKey')),
    );
    expect(reqs, isEmpty);
  });
}
