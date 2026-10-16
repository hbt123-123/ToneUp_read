import 'dart:convert';

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

/// 与 lib/services/remote_article_service.dart 里拼出来的 SQL 逐字对应。
const String _metaInsertSql =
    'INSERT INTO articles (guid, remoteId, source, title, summary, publishedAt, expiresAt, status, remoteFetchedAt) '
    'VALUES (?,?,?,?,?,?,?,?,?)';

const String _metaUpdateSql =
    'UPDATE articles SET remoteId = ?, source = ?, summary = ?, publishedAt = ?, expiresAt = ?, status = ?, remoteFetchedAt = ? '
    'WHERE id = ?';

const String _metaUpdateTitleSql =
    'UPDATE articles SET remoteId = ?, source = ?, summary = ?, publishedAt = ?, expiresAt = ?, status = ?, remoteFetchedAt = ?, title = ? '
    'WHERE id = ?';

const String _goneSql = 'UPDATE articles SET status = ? WHERE id = ?';

const String _fullInsertSql =
    'INSERT INTO articles (guid, sourceUrl, title, author, plainText, blocks, wordCount, capturedAt, '
    'remoteId, source, summary, publishedAt, expiresAt, status, aiVerdict, remoteFetchedAt, cachedAt) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';

const String _fullUpdateSql =
    'UPDATE articles SET sourceUrl = ?, title = ?, author = ?, plainText = ?, blocks = ?, wordCount = ?, '
    'remoteId = ?, source = ?, summary = ?, publishedAt = ?, expiresAt = ?, status = ?, aiVerdict = ?, '
    'remoteFetchedAt = ?, cachedAt = ? WHERE id = ?';

const String _cachedListSql =
    "SELECT * FROM articles WHERE (cachedAt IS NOT NULL OR IFNULL(plainText,'') <> '') ORDER BY IFNULL(cachedAt, 0) DESC";

const String _cachedListSourceSql =
    "SELECT * FROM articles WHERE (cachedAt IS NOT NULL OR IFNULL(plainText,'') <> '') AND source = ? "
    "ORDER BY IFNULL(cachedAt, 0) DESC";

const String _detailPath = '/v1/articles/42';

class _Op {
  _Op(this.sql, this.params);
  final String sql;
  final List<Object?>? params;
}

/// 内存版 articles / title_zh：只实现 RemoteArticleService 用到的几条 SQL，
/// 同时把 select/execute 的语句与参数记录下来供断言。
class _TestDb extends FakeDb {
  final List<_Op> executed = [];
  final List<_Op> selected = [];
  final List<Map<String, dynamic>> articles = [];
  int _seq = 0;

  void seed(Map<String, dynamic> row) {
    articles.add(Map<String, dynamic>.of(row));
    final id = row['id'] as int;
    if (id > _seq) _seq = id;
  }

  Map<String, dynamic> byId(int id) => articles.firstWhere((r) => r['id'] == id);

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    selected.add(_Op(sql, params));
    if (sql.startsWith('SELECT id FROM articles WHERE guid = ?')) {
      final guid = params?[0];
      return [for (final r in articles) if (r['guid'] == guid) {'id': r['id']}];
    }
    if (sql.contains('FROM articles WHERE remoteId = ?')) {
      final rid = params?[0];
      return [
        for (final r in articles)
          if (r['remoteId'] == rid) {'id': r['id'], 'plainText': r['plainText']}
      ];
    }
    if (sql.startsWith('SELECT guid FROM articles')) {
      return [
        for (final r in articles)
          if ('${r['plainText'] ?? ''}'.trim().isNotEmpty) {'guid': r['guid']}
      ];
    }
    if (sql.startsWith('SELECT * FROM articles')) {
      var rows = articles
          .where((r) => r['cachedAt'] != null || '${r['plainText'] ?? ''}'.trim().isNotEmpty)
          .toList();
      if (params != null && params.isNotEmpty) {
        final source = params[0];
        rows = rows.where((r) => r['source'] == source).toList();
      }
      rows.sort((a, b) => ((b['cachedAt'] ?? 0) as num).compareTo((a['cachedAt'] ?? 0) as num));
      return [for (final r in rows) Map<String, dynamic>.of(r)];
    }
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {
    executed.add(_Op(sql, params));
    final p = params ?? const <Object?>[];
    if (sql.startsWith('INSERT INTO articles (guid, remoteId')) {
      articles.add({
        'id': ++_seq,
        'guid': p[0],
        'remoteId': p[1],
        'source': p[2],
        'title': p[3],
        'summary': p[4],
        'publishedAt': p[5],
        'expiresAt': p[6],
        'status': p[7],
        'remoteFetchedAt': p[8],
      });
    } else if (sql.startsWith('UPDATE articles SET remoteId = ?')) {
      final withTitle = sql.contains(', title = ?');
      final row = byId((withTitle ? p[8] : p[7]) as int);
      row['remoteId'] = p[0];
      row['source'] = p[1];
      row['summary'] = p[2];
      row['publishedAt'] = p[3];
      row['expiresAt'] = p[4];
      row['status'] = p[5];
      row['remoteFetchedAt'] = p[6];
      if (withTitle) row['title'] = p[7];
    } else if (sql.startsWith('UPDATE articles SET status = ?')) {
      byId(p[1] as int)['status'] = p[0];
    } else if (sql.startsWith('UPDATE articles SET sourceUrl = ?')) {
      final row = byId(p[15] as int);
      row['sourceUrl'] = p[0];
      row['title'] = p[1];
      row['author'] = p[2];
      row['plainText'] = p[3];
      row['blocks'] = p[4];
      row['wordCount'] = p[5];
      row['remoteId'] = p[6];
      row['source'] = p[7];
      row['summary'] = p[8];
      row['publishedAt'] = p[9];
      row['expiresAt'] = p[10];
      row['status'] = p[11];
      row['aiVerdict'] = p[12];
      row['remoteFetchedAt'] = p[13];
      row['cachedAt'] = p[14];
    } else if (sql.startsWith('INSERT INTO articles (guid, sourceUrl')) {
      fail('整行 INSERT 必须走 insertReturnId，不该出现在 execute 里');
    }
  }

  @override
  Future<int> insertReturnId(String sql, [List<Object?>? params]) async {
    executed.add(_Op(sql, params));
    expect(sql, _fullInsertSql);
    final p = params!;
    final id = ++_seq;
    articles.add({
      'id': id,
      'guid': p[0],
      'sourceUrl': p[1],
      'title': p[2],
      'author': p[3],
      'plainText': p[4],
      'blocks': p[5],
      'wordCount': p[6],
      'capturedAt': p[7],
      'remoteId': p[8],
      'source': p[9],
      'summary': p[10],
      'publishedAt': p[11],
      'expiresAt': p[12],
      'status': p[13],
      'aiVerdict': p[14],
      'remoteFetchedAt': p[15],
      'cachedAt': p[16],
    });
    return id;
  }
}

/// 这些用例不该触发标题翻译；真触发了就抛错让用例红。
class _UnusedTranslate extends TranslateService {
  _UnusedTranslate() : super(LlmService(HttpService(), AppConfigService()));
  int calls = 0;

  @override
  Future<String> translate(String text, {String from = 'en', String to = 'zh'}) async {
    calls++;
    throw StateError('list/cache 用例不应触发标题翻译：$text');
  }
}

Map<String, String> get _jsonHeaders => {'content-type': 'application/json'};

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

/// 按源码读取路径注入：`article_api_base` / `article_api_key`（FLUTTER_TEST 下密钥回落明文）。
Future<AppConfigService> _config({String articleKey = 'art-key'}) async {
  SharedPreferences.setMockInitialValues({
    'article_api_base': 'https://api.test',
    'article_api_key': articleKey,
    'gateway_base': 'https://gw.test',
    'gateway_key': 'gw-key',
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

_Op _oneExec(_TestDb db, String sql) {
  final hits = db.executed.where((e) => e.sql == sql).toList();
  expect(hits, hasLength(1), reason: '期望恰好一次执行：$sql');
  return hits.single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('list() 拼 URL/鉴权头，并把元信息 INSERT 进本地（秒→毫秒）', () async {
    final cfg = await _config();
    final db = _TestDb();
    final tr = _UnusedTranslate();
    final reqs = <http.Request>[];
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        reqs.add(req);
        return _ok({
          'items': [
            {
              'id': 7,
              'url': 'https://x.test/a',
              'source': 'bbc',
              'title': 'Alpha',
              'summary': 'sum',
              'published_at': 1700000000,
              'status': 'accepted',
            },
          ],
          'total': 1,
          'page': 2,
          'perPage': 5,
        });
      })),
      cfg,
      tr,
    );

    final t0 = DateTime.now().millisecondsSinceEpoch;
    final res = await svc.list(source: 'bbc news', status: 'accepted', page: 2, perPage: 5);
    final t1 = DateTime.now().millisecondsSinceEpoch;

    expect(res['total'], 1);
    expect(res['items'], hasLength(1));
    expect(reqs, hasLength(1));
    final req = reqs.single;
    expect(req.method, 'GET');
    expect(req.url.toString(), 'https://api.test/v1/articles?source=bbc%20news&status=accepted&page=2&per_page=5');
    expect(req.headers['X-API-Key'], 'art-key');

    final ins = _oneExec(db, _metaInsertSql);
    final p = ins.params!;
    expect(p, hasLength(9));
    expect(p[0], 'https://x.test/a', reason: 'guid = url');
    expect(p[1], 7);
    expect(p[2], 'bbc');
    expect(p[3], 'Alpha');
    expect(p[4], 'sum');
    expect(p[5], 1700000000000, reason: 'epoch 秒 ×1000 → 毫秒');
    expect(p[6], isNull, reason: '缺省 expires_at → null');
    expect(p[7], 'accepted');
    expect(p[8], allOf(isA<int>(), greaterThanOrEqualTo(t0), lessThanOrEqualTo(t1)));

    final row = db.articles.single;
    expect(row['plainText'], isNull, reason: '元信息回写不碰正文字段');
    expect(row['cachedAt'], isNull);
    expect(row['capturedAt'], isNull);
    expect(tr.calls, 0);
  });

  test('list() 已有同 guid 行走 UPDATE，title 非空时才带 title = ?', () async {
    final cfg = await _config();
    final db = _TestDb()..seed({'id': 1, 'guid': 'https://x.test/a', 'title': 'Old', 'source': 'cnn'});
    final tr = _UnusedTranslate();
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        return _ok({
          'items': [
            {
              'id': 7,
              'url': 'https://x.test/a',
              'source': 'bbc',
              'title': 'Beta',
              'summary': 'sum',
              'published_at': 1700000000,
              'expires_at': 1700036000,
              'status': 'accepted',
            },
          ],
          'total': 1,
          'page': 1,
          'perPage': 20,
        });
      })),
      cfg,
      tr,
    );

    final t0 = DateTime.now().millisecondsSinceEpoch;
    final res = await svc.list();
    final t1 = DateTime.now().millisecondsSinceEpoch;

    expect(res['items'], hasLength(1));
    final upd = _oneExec(db, _metaUpdateTitleSql);
    final p = upd.params!;
    expect(p, hasLength(9));
    expect(p[0], 7);
    expect(p[1], 'bbc');
    expect(p[2], 'sum');
    expect(p[3], 1700000000000);
    expect(p[4], 1700036000000);
    expect(p[5], 'accepted');
    expect(p[6], allOf(isA<int>(), greaterThanOrEqualTo(t0), lessThanOrEqualTo(t1)));
    expect(p[7], 'Beta');
    expect(p[8], 1, reason: '按 guid 命中的本地行 id');

    final row = db.byId(1);
    expect(row['title'], 'Beta');
    expect(row['source'], 'bbc');
    expect(row['publishedAt'], 1700000000000);
  });

  test('list() title 为空白时不更新 title 列（SQL 少一个占位符）', () async {
    final cfg = await _config();
    final db = _TestDb()..seed({'id': 2, 'guid': 'https://x.test/b', 'title': 'KeepMe'});
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        return _ok({
          'items': [
            {
              'id': 8,
              'url': 'https://x.test/b',
              'source': 'cnn',
              'title': '   ',
              'summary': 'sum2',
              'status': 'pending',
            },
          ],
          'total': 1,
          'page': 1,
          'perPage': 20,
        });
      })),
      cfg,
      _UnusedTranslate(),
    );

    await svc.list();

    final upd = _oneExec(db, _metaUpdateSql);
    final p = upd.params!;
    expect(p, hasLength(8));
    expect(p[0], 8);
    expect(p[1], 'cnn');
    expect(p[2], 'sum2');
    expect(p[3], isNull);
    expect(p[4], isNull);
    expect(p[5], 'pending');
    expect(p[7], 2);
    expect(db.byId(2)['title'], 'KeepMe', reason: '空白标题保留本地原标题');
  });

  test('cacheArticle 已有正文时直接返回本地 id，不发请求', () async {
    final cfg = await _config();
    final db = _TestDb()
      ..seed({
        'id': 3,
        'guid': 'https://x.test/a',
        'remoteId': 42,
        'plainText': 'Cached body.',
        'cachedAt': 1000,
      });
    final reqs = <http.Request>[];
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        reqs.add(req);
        return _ok(<String, dynamic>{});
      })),
      cfg,
      _UnusedTranslate(),
    );

    expect(await svc.cacheArticle(42), 3);
    expect(reqs, isEmpty);
    expect(db.executed, isEmpty);
    expect(db.selected, hasLength(1), reason: '只有一次本地查询，没有第二次网络/写库');
  });

  test('cacheArticle 详情成功：落 plainText / blocks（空行切段）/ 时间毫秒', () async {
    final cfg = await _config();
    final db = _TestDb();
    final reqs = <http.Request>[];
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        reqs.add(req);
        return _ok({
          'id': 42,
          'url': 'https://x.test/a',
          'title': 'Alpha',
          'author': 'Ann',
          'text': 'First para.\n\nSecond para.\n   \nThird',
          'source': 'bbc',
          'summary': 'sum',
          'published_at': 1700000000,
          'expires_at': 1700036000,
          'status': 'accepted',
          'ai_verdict': {
            'ok': true,
            'score': 0.9,
          },
        });
      })),
      cfg,
      _UnusedTranslate(),
    );

    final t0 = DateTime.now().millisecondsSinceEpoch;
    final id = await svc.cacheArticle(42);
    final t1 = DateTime.now().millisecondsSinceEpoch;

    expect(reqs, hasLength(1));
    expect(reqs.single.method, 'GET');
    expect(reqs.single.url.path, _detailPath);
    expect(reqs.single.headers['X-API-Key'], 'art-key');

    expect(id, isA<int>());
    final ins = _oneExec(db, _fullInsertSql);
    final p = ins.params!;
    expect(p, hasLength(17));
    expect(p[0], 'https://x.test/a', reason: 'guid = url');
    expect(p[1], 'https://x.test/a', reason: 'sourceUrl 同 guid');
    expect(p[2], 'Alpha');
    expect(p[3], 'Ann');
    expect(p[4], 'First para.\n\nSecond para.\n   \nThird');
    expect(p[5], jsonEncode([
      {'type': 'p', 'text': 'First para.'},
      {'type': 'p', 'text': 'Second para.'},
      {'type': 'p', 'text': 'Third'},
    ]));
    expect(p[6], 5, reason: '无 word_count 时本地按空白切词');
    expect(p[8], 42);
    expect(p[9], 'bbc');
    expect(p[10], 'sum');
    expect(p[11], 1700000000000);
    expect(p[12], 1700036000000);
    expect(p[13], 'accepted');
    expect(p[14], '{"ok":true,"score":0.9}');
    expect(p[7], allOf(isA<int>(), greaterThanOrEqualTo(t0), lessThanOrEqualTo(t1)));
    expect(p[15], p[7], reason: 'remoteFetchedAt = capturedAt = cachedAt');
    expect(p[16], p[7]);

    final row = db.byId(id as int);
    expect(row['plainText'], 'First para.\n\nSecond para.\n   \nThird');
    expect(jsonDecode('${row['blocks']}'), [
      {'type': 'p', 'text': 'First para.'},
      {'type': 'p', 'text': 'Second para.'},
      {'type': 'p', 'text': 'Third'},
    ]);
    expect(row['wordCount'], 5);
    expect(row['remoteId'], 42);
    expect(row['cachedAt'], p[16]);
  });

  test('cacheArticle：text 为空仍缓存元信息，blocks 为 []', () async {
    final cfg = await _config();
    final db = _TestDb();
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        return _ok({
          'id': 7,
          'url': 'https://x.test/e',
          'title': 'Empty',
          'text': '',
          'status': 'accepted',
        });
      })),
      cfg,
      _UnusedTranslate(),
    );

    final id = await svc.cacheArticle(7);

    expect(id, isA<int>());
    final row = db.byId(id as int);
    expect(row['plainText'], '');
    expect(row['blocks'], '[]');
    expect(row['wordCount'], 0);
    expect(row['title'], 'Empty');
    expect(row['remoteId'], 7);
    expect(row['aiVerdict'], isNull);
    expect(row['cachedAt'], isA<int>());
  });

  test('cacheArticle force=true：已有正文也重新拉取并整行 UPDATE（word_count 优先）', () async {
    final cfg = await _config();
    final db = _TestDb()
      ..seed({
        'id': 5,
        'guid': 'https://x.test/a',
        'remoteId': 42,
        'title': 'Old',
        'plainText': 'Old body.',
        'cachedAt': 1000,
      });
    final reqs = <http.Request>[];
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async {
        reqs.add(req);
        return _ok({
          'id': 42,
          'url': 'https://x.test/a',
          'title': 'New',
          'text': 'New body here.',
          'word_count': 99,
          'status': 'accepted',
        });
      })),
      cfg,
      _UnusedTranslate(),
    );

    final id = await svc.cacheArticle(42, force: true);

    expect(id, 5);
    expect(reqs, hasLength(1));
    final upd = _oneExec(db, _fullUpdateSql);
    final p = upd.params!;
    expect(p, hasLength(16));
    expect(p[0], 'https://x.test/a');
    expect(p[1], 'New');
    expect(p[3], 'New body here.');
    expect(p[4], jsonEncode([
      {'type': 'p', 'text': 'New body here.'},
    ]));
    expect(p[5], 99, reason: '接口给了 word_count 就不本地数词');
    expect(p[15], 5, reason: 'WHERE id = 本地行');
    expect(db.byId(5)['cachedAt'], p[14]);
  });

  test('cacheArticle 404：本地有行 → 置 gone 保留副本；本地无行 → null', () async {
    final cfg = await _config();

    // 本地有行
    final db1 = _TestDb()..seed({'id': 9, 'guid': 'g-77', 'remoteId': 77, 'plainText': ''});
    final reqs1 = <http.Request>[];
    final svc1 = RemoteArticleService(
      db1,
      HttpService(client: MockClient((req) async {
        reqs1.add(req);
        return http.Response('gone', 404);
      })),
      cfg,
      _UnusedTranslate(),
    );
    expect(await svc1.cacheArticle(77), 9);
    expect(reqs1, hasLength(1));
    final gone = _oneExec(db1, _goneSql);
    expect(gone.params, ['gone', 9]);
    expect(db1.byId(9)['status'], 'gone');

    // 本地无行
    final db2 = _TestDb();
    final reqs2 = <http.Request>[];
    final svc2 = RemoteArticleService(
      db2,
      HttpService(client: MockClient((req) async {
        reqs2.add(req);
        return http.Response('gone', 404);
      })),
      cfg,
      _UnusedTranslate(),
    );
    expect(await svc2.cacheArticle(78), isNull);
    expect(reqs2, hasLength(1));
    expect(db2.executed, isEmpty);
  });

  test('cachedGuids / localIdForGuid / cachedArticles 只认已缓存的行', () async {
    final cfg = await _config();
    final db = _TestDb()
      ..seed({'id': 1, 'guid': 'g1', 'source': 'bbc', 'plainText': 'hello', 'cachedAt': 1000})
      ..seed({'id': 2, 'guid': 'g2', 'source': 'cnn', 'plainText': '', 'cachedAt': 5000})
      ..seed({'id': 3, 'guid': 'g3', 'source': 'bbc', 'plainText': '', 'cachedAt': null});
    final svc = RemoteArticleService(
      db,
      HttpService(client: MockClient((req) async => http.Response('no network', 500))),
      cfg,
      _UnusedTranslate(),
    );

    expect(await svc.cachedGuids(), {'g1'}, reason: 'plainText 为空不算已缓存');

    expect(await svc.localIdForGuid('g1'), 1);
    expect(await svc.localIdForGuid('missing'), isNull);
    expect(await svc.localIdForGuid('   '), isNull);

    final all = await svc.cachedArticles();
    expect(all.map((e) => e['id']).toList(), [2, 1], reason: 'cachedAt 倒序，既无正文又无 cachedAt 的行不出现');
    expect(db.selected.last.sql, _cachedListSql);

    final bySource = await svc.cachedArticles(source: 'bbc');
    expect(bySource.map((e) => e['id']).toList(), [1]);
    expect(db.selected.last.sql, _cachedListSourceSql);
    expect(db.selected.last.params, ['bbc']);
  });
}
