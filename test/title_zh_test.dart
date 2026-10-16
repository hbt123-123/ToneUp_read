import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/remote_article_service.dart';
import 'package:toneup_read/services/translate_service.dart';

import 'fake_db.dart';

const String _titleZhSql = 'INSERT OR REPLACE INTO title_zh (title, zh, at) VALUES (?,?,?)';
const String _titleZhSelectPrefix = 'SELECT title, zh FROM title_zh WHERE title IN (';

class _Write {
  _Write(this.sql, this.params);
  final String sql;
  final List<Object?> params;
}

/// titleZhBatch 只碰 title_zh 一张表：select 查缓存、execute 回写。
class _Db extends FakeDb {
  final Map<String, String> titleZh = {};
  final List<_Write> writes = [];
  final List<String> selectedSqls = [];
  int selects = 0;

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    selects++;
    selectedSqls.add(sql);
    final want = <String>{for (final p in params ?? const <Object?>[]) '$p'};
    return [
      for (final e in titleZh.entries)
        if (want.contains(e.key)) {'title': e.key, 'zh': e.value},
    ];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {
    final p = params ?? const <Object?>[];
    writes.add(_Write(sql, p));
    titleZh['${p[0]}'] = '${p[1]}';
  }
}

/// 假翻译引擎：只替换 `TranslateService.translate`，不碰网络。
/// （源码构造是 TranslateService(LlmService(...)) 单参数。）
class _FakeTranslate extends TranslateService {
  _FakeTranslate() : super(LlmService(HttpService(), AppConfigService()));

  int calls = 0;
  String lastText = '';
  String lastFrom = '';
  String lastTo = '';
  String result = '你好';
  Object? error;
  Set<String> failOn = {};
  Duration delay = Duration.zero;

  @override
  Future<String> translate(String text, {String from = 'en', String to = 'zh'}) async {
    calls++;
    lastText = text;
    lastFrom = from;
    lastTo = to;
    if (delay > Duration.zero) await Future.delayed(delay);
    if (failOn.contains(text)) throw StateError('translate failed: $text');
    final e = error;
    if (e != null) throw e;
    return result;
  }
}

/// titleZhBatch 不直接打网络：真打到了就记下来断言 0 次。
RemoteArticleService _svc(_Db db, _FakeTranslate tr, List<http.Request> reqs) {
  return RemoteArticleService(
    db,
    HttpService(client: MockClient((req) async {
      reqs.add(req);
      return http.Response('{"error":"not used"}', 500);
    })),
    AppConfigService(),
    tr,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('命中 title_zh 时不发翻译请求', () async {
    final db = _Db()..titleZh['Hello World'] = '你好世界';
    final tr = _FakeTranslate();
    final reqs = <http.Request>[];
    final svc = _svc(db, tr, reqs);

    final out = await svc.titleZhBatch(['Hello World']);

    expect(out, {'Hello World': '你好世界'});
    expect(tr.calls, 0);
    expect(reqs, isEmpty);
    expect(db.writes, isEmpty);
    expect(db.selects, 1);
    expect(db.selectedSqls.single.startsWith(_titleZhSelectPrefix), isTrue);
  });

  test('缺失标题调翻译并按 title/zh/at 写回，之后直接命中缓存', () async {
    final db = _Db();
    final tr = _FakeTranslate()..result = '你好世界';
    final reqs = <http.Request>[];
    final svc = _svc(db, tr, reqs);

    final out = await svc.titleZhBatch(['Hello World']);

    expect(out, {'Hello World': '你好世界'});
    expect(tr.calls, 1);
    expect(tr.lastText, 'Hello World');
    expect(tr.lastFrom, 'en');
    expect(tr.lastTo, 'zh');
    expect(reqs, isEmpty);

    expect(db.writes, hasLength(1));
    final w = db.writes.single;
    expect(w.sql, _titleZhSql);
    expect(w.params[0], 'Hello World');
    expect(w.params[1], '你好世界');
    expect(w.params[2], isA<int>(), reason: 'at 是 epoch 毫秒');

    // 第二次同名标题直接走 title_zh，不再翻译。
    final again = await svc.titleZhBatch(['Hello World']);
    expect(again, {'Hello World': '你好世界'});
    expect(tr.calls, 1);
    expect(db.writes, hasLength(1));
  });

  test('批内重复标题只翻译一次', () async {
    final db = _Db();
    final tr = _FakeTranslate();
    final svc = _svc(db, tr, <http.Request>[]);

    final out = await svc.titleZhBatch(['Dup', ' Dup ']);

    expect(out, {'Dup': '你好'});
    expect(tr.calls, 1);
    expect(db.writes, hasLength(1));
  });

  test('并发批次命中同一 in-flight 只翻译一次', () async {
    final db = _Db();
    final tr = _FakeTranslate()..delay = const Duration(milliseconds: 80);
    final reqs = <http.Request>[];
    final svc = _svc(db, tr, reqs);

    final results = await Future.wait([
      svc.titleZhBatch(['Concurrent']),
      svc.titleZhBatch(['Concurrent']),
    ]);

    expect(results[0], {'Concurrent': '你好'});
    expect(results[1], {'Concurrent': '你好'});
    expect(tr.calls, 1, reason: '两个批次共享同一个 in-flight Future');
    expect(db.writes, hasLength(1));
    expect(reqs, isEmpty);
  });

  test('翻译抛错时静默跳过，并进入 60 秒冷却（第二次不再重试）', () async {
    final db = _Db();
    final tr = _FakeTranslate()..error = StateError('boom');
    final svc = _svc(db, tr, <http.Request>[]);

    final first = await svc.titleZhBatch(['Bad']);
    expect(first, isEmpty, reason: '失败的标题不进结果，调用方回落英文标题');
    expect(tr.calls, 1);
    expect(db.writes, isEmpty);

    final second = await svc.titleZhBatch(['Bad']);
    expect(second, isEmpty);
    expect(tr.calls, 1, reason: '60 秒冷却内不再重试');
    expect(db.selects, 2, reason: '冷却拦截发生在查 title_zh 之后、翻译之前');
  });

  test('翻译返回原文视为失败并进入冷却', () async {
    final db = _Db();
    final tr = _FakeTranslate()..result = 'Same Title';
    final svc = _svc(db, tr, <http.Request>[]);

    expect(await svc.titleZhBatch(['Same Title']), isEmpty);
    expect(tr.calls, 1);
    expect(db.writes, isEmpty);

    expect(await svc.titleZhBatch(['Same Title']), isEmpty);
    expect(tr.calls, 1);
  });

  test('部分标题失败不影响其它标题', () async {
    final db = _Db();
    final tr = _FakeTranslate()
      ..failOn = {'Bad'}
      ..result = '好';
    final svc = _svc(db, tr, <http.Request>[]);

    final out = await svc.titleZhBatch(['Good', 'Bad']);

    expect(out, {'Good': '好'});
    expect(tr.calls, 2);
    expect(db.writes, hasLength(1));
  });

  test('空白标题直接返回，不查库不翻译', () async {
    final db = _Db();
    final tr = _FakeTranslate();
    final reqs = <http.Request>[];
    final svc = _svc(db, tr, reqs);

    expect(await svc.titleZhBatch(['', '   ']), isEmpty);
    expect(db.selects, 0);
    expect(tr.calls, 0);
    expect(db.writes, isEmpty);
    expect(reqs, isEmpty);
  });
}
