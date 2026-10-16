import 'dart:convert';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/translate_service.dart';

/// 云端文章接口（`articleApiBase`，`X-API-Key` 鉴权）的本地缓存层：
/// 列表/详情从接口来，元信息与正文按 `guid = url` UPSERT 进本地 `articles` 表，
/// 离线时用 `cachedArticles()` 兜底。所有时间列存 epoch 毫秒（接口的秒 ×1000）。
class RemoteArticleService {
  RemoteArticleService(this._db, this._http, this._cfg, this._translate);

  final DbService _db;
  final HttpService _http;
  final AppConfigService _cfg;
  final TranslateService _translate;

  /// 标题翻译：进程内 in-flight 去重 + 失败 60 秒冷却。
  static const int _failTtlMs = 60000;
  final Map<String, Future<String?>> _inflight = {};
  final Map<String, int> _failedAt = {};

  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 接口返回的 epoch 秒 → 本地 epoch 毫秒。
  int? _ms(Object? sec) {
    if (sec is! num) return null;
    return sec.toInt() * 1000;
  }

  Map<String, String> get _auth => {'X-API-Key': _cfg.articleApiKey};

  /// 文章列表（原始响应：items/total/page/perPage），并把每条元信息回写本地表。
  Future<Map<String, dynamic>> list({
    String? source,
    String status = 'accepted',
    int page = 1,
    int perPage = 20,
  }) async {
    final qs = <String>[
      if (source != null && source.isNotEmpty) 'source=${Uri.encodeComponent(source)}',
      'status=${Uri.encodeComponent(status)}',
      'page=$page',
      'per_page=$perPage',
    ];
    final url = '${_cfg.articleApiBase}/v1/articles?${qs.join('&')}';
    final res = await _http.getJson(url, headers: _auth);
    final items = res['items'];
    if (items is List) {
      for (final it in items) {
        if (it is! Map) continue;
        // 元信息回写是缓存增强，单条失败不影响列表返回。
        try {
          await _upsertMeta(Map<String, dynamic>.from(it));
        } catch (_) {}
      }
    }
    return res;
  }

  /// 文章详情（含正文 text / ai_verdict）；远端已删（404）返回 null。
  Future<Map<String, dynamic>?> detail(int remoteId) async {
    try {
      return await _http.getJson('${_cfg.articleApiBase}/v1/articles/$remoteId', headers: _auth);
    } on AppException catch (e) {
      if (e.code == 'http404') return null;
      rethrow;
    }
  }

  /// 只写云端元信息：不碰 plainText / blocks / cachedAt / capturedAt 等本地正文字段。
  Future<void> _upsertMeta(Map<String, dynamic> item) async {
    final guid = '${item['url'] ?? ''}';
    if (guid.trim().isEmpty) return;
    final now = nowMs();
    final remoteId = item['id'] is num ? (item['id'] as num).toInt() : null;
    final source = item['source']?.toString();
    final title = item['title']?.toString();
    final summary = item['summary']?.toString();
    final publishedAt = _ms(item['published_at']);
    final expiresAt = _ms(item['expires_at']);
    final status = item['status']?.toString();

    final rows = await _db.select('SELECT id FROM articles WHERE guid = ?', [guid]);
    if (rows.isEmpty) {
      await _db.execute(
        'INSERT INTO articles (guid, remoteId, source, title, summary, publishedAt, expiresAt, status, remoteFetchedAt) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        [guid, remoteId, source, title, summary, publishedAt, expiresAt, status, now],
      );
      return;
    }
    await _db.execute(
      'UPDATE articles SET remoteId = ?, source = ?, summary = ?, publishedAt = ?, expiresAt = ?, status = ?, remoteFetchedAt = ?'
      '${title != null && title.trim().isNotEmpty ? ', title = ?' : ''} WHERE id = ?',
      title != null && title.trim().isNotEmpty
          ? [remoteId, source, summary, publishedAt, expiresAt, status, now, title, rows.first['id']]
          : [remoteId, source, summary, publishedAt, expiresAt, status, now, rows.first['id']],
    );
  }

  /// 拉正文并落库。已有正文且非 force 时直接返回本地 id；
  /// 远端 404：本地有行 → 标记 `status='gone'` 保留副本并返回其 id，本地无行 → null。
  Future<int?> cacheArticle(int remoteId, {bool force = false}) async {
    final local = await _db.select('SELECT id, plainText FROM articles WHERE remoteId = ? LIMIT 1', [remoteId]);
    final localId = local.isEmpty ? null : local.first['id'] as int;
    final hasText = local.isNotEmpty && ('${local.first['plainText'] ?? ''}').trim().isNotEmpty;
    if (!force && hasText) return localId;

    final d = await detail(remoteId);
    if (d == null) {
      if (localId != null) {
        await _db.execute('UPDATE articles SET status = ? WHERE id = ?', ['gone', localId]);
        return localId;
      }
      return null;
    }
    return _upsertFull(d, localId);
  }

  Future<int?> _upsertFull(Map<String, dynamic> d, int? knownId) async {
    final guid = '${d['url'] ?? ''}';
    if (guid.trim().isEmpty) return null;
    final now = nowMs();
    final text = '${d['text'] ?? ''}';
    final blocks = jsonEncode(_blocksOf(text));
    final apiWc = d['word_count'] is num ? (d['word_count'] as num).toInt() : null;
    final wordCount = apiWc ?? _countWords(text);
    final remoteId = d['id'] is num ? (d['id'] as num).toInt() : null;
    final aiVerdict = d['ai_verdict'] == null ? null : jsonEncode(d['ai_verdict']);
    final publishedAt = _ms(d['published_at']);
    final expiresAt = _ms(d['expires_at']);

    var id = knownId;
    if (id == null) {
      final rows = await _db.select('SELECT id FROM articles WHERE guid = ?', [guid]);
      id = rows.isEmpty ? null : rows.first['id'] as int;
    }
    if (id == null) {
      return _db.insertReturnId(
        'INSERT INTO articles (guid, sourceUrl, title, author, plainText, blocks, wordCount, capturedAt, '
        'remoteId, source, summary, publishedAt, expiresAt, status, aiVerdict, remoteFetchedAt, cachedAt) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          guid,
          guid,
          d['title']?.toString(),
          d['author']?.toString(),
          text,
          blocks,
          wordCount,
          now,
          remoteId,
          d['source']?.toString(),
          d['summary']?.toString(),
          publishedAt,
          expiresAt,
          d['status']?.toString(),
          aiVerdict,
          now,
          now,
        ],
      );
    }
    // 只覆盖正文与云端元信息字段，不碰 curated_blocks / html / cachedAt 之外的本地状态。
    await _db.execute(
      'UPDATE articles SET sourceUrl = ?, title = ?, author = ?, plainText = ?, blocks = ?, wordCount = ?, '
      'remoteId = ?, source = ?, summary = ?, publishedAt = ?, expiresAt = ?, status = ?, aiVerdict = ?, '
      'remoteFetchedAt = ?, cachedAt = ? WHERE id = ?',
      [
        guid,
        d['title']?.toString(),
        d['author']?.toString(),
        text,
        blocks,
        wordCount,
        remoteId,
        d['source']?.toString(),
        d['summary']?.toString(),
        publishedAt,
        expiresAt,
        d['status']?.toString(),
        aiVerdict,
        now,
        now,
        id,
      ],
    );
    return id;
  }

  /// 正文按空行切段，产出与 `ArticleBlock` 一致的 `{type:'p', text:...}` 结构。
  List<Map<String, dynamic>> _blocksOf(String text) {
    final out = <Map<String, dynamic>>[];
    for (final part in text.split(RegExp(r'\n\s*\n'))) {
      final s = part.trim();
      if (s.isEmpty) continue;
      out.add({'type': 'p', 'text': s});
    }
    return out;
  }

  int _countWords(String text) {
    final s = text.trim();
    if (s.isEmpty) return 0;
    return s.split(RegExp(r'\s+')).length;
  }

  Future<int?> localIdForGuid(String guid) async {
    if (guid.trim().isEmpty) return null;
    final rows = await _db.select('SELECT id FROM articles WHERE guid = ? LIMIT 1', [guid]);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// 已缓存正文（plainText 非空）的 guid 集合，供首页「已缓存」标记。
  Future<Set<String>> cachedGuids() async {
    final rows = await _db.select("SELECT guid FROM articles WHERE guid IS NOT NULL AND IFNULL(plainText,'') <> ''");
    return rows.map((r) => '${r['guid']}').where((g) => g.isNotEmpty).toSet();
  }

  /// 离线兜底列表：本地已缓存（cachedAt 有值或已有正文）的行，按 cachedAt 倒序。
  Future<List<Map<String, dynamic>>> cachedArticles({String? source}) async {
    final where = StringBuffer("(cachedAt IS NOT NULL OR IFNULL(plainText,'') <> '')");
    final args = <Object?>[];
    if (source != null && source.isNotEmpty) {
      where.write(' AND source = ?');
      args.add(source);
    }
    final rows = await _db.select(
      'SELECT * FROM articles WHERE $where ORDER BY IFNULL(cachedAt, 0) DESC',
      args,
    );
    return rows.map((e) => Map<String, dynamic>.of(e)).toList();
  }

  /// 批量取标题中译：先查 `title_zh`，缺失的并发（≤3）走网关翻译并回写。
  /// 单个失败静默跳过（调用方回落英文标题）。
  Future<Map<String, String>> titleZhBatch(List<String> titles) async {
    final out = <String, String>{};
    final need = <String>{};
    for (final t in titles) {
      final s = t.trim();
      if (s.isNotEmpty) need.add(s);
    }
    if (need.isEmpty) return out;

    for (final chunk in chunked(need.toList())) {
      final ph = List.filled(chunk.length, '?').join(',');
      final rows = await _db.select('SELECT title, zh FROM title_zh WHERE title IN ($ph)', chunk);
      for (final r in rows) {
        final t = '${r['title']}';
        out[t] = '${r['zh']}';
        need.remove(t);
      }
    }
    final missing = need.toList();
    if (missing.isEmpty) return out;

    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= missing.length) return;
        final t = missing[i];
        final zh = await _translateOne(t);
        if (zh != null) out[t] = zh;
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
    return out;
  }

  Future<String?> _translateOne(String title) async {
    final failAt = _failedAt[title];
    if (failAt != null && nowMs() - failAt < _failTtlMs) return null;
    final pending = _inflight[title];
    if (pending != null) return pending;
    final future = _doTranslate(title);
    _inflight[title] = future;
    try {
      final zh = await future;
      if (zh == null) {
        _failedAt[title] = nowMs();
      } else {
        _failedAt.remove(title);
      }
      return zh;
    } finally {
      _inflight.remove(title);
    }
  }

  Future<String?> _doTranslate(String title) async {
    try {
      final zh = (await _translate.translate(title, from: 'en', to: 'zh')).trim();
      if (zh.isEmpty || zh.toLowerCase() == title.toLowerCase()) return null;
      await _db.execute('INSERT OR REPLACE INTO title_zh (title, zh, at) VALUES (?,?,?)', [title, zh, nowMs()]);
      return zh;
    } catch (_) {
      return null;
    }
  }
}
