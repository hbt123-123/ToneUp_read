import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// 单条 SQL 的绑定变量上限：旧版 Android 的 SQLite（< 3.32）为 999。
/// 统一按此大小切片，所有 `IN (...)` 大列表查询都必须分批，避免 "too many SQL variables"
/// （例如标题中译批量回写时一次传入上千个 title）。
const int sqlBindChunk = 400;

/// 将列表按 [size] 切片，供过大的 `IN (...)` 拆成多条查询复用。
Iterable<List<T>> chunked<T>(List<T> items, [int size = sqlBindChunk]) sync* {
  for (var i = 0; i < items.length; i += size) {
    yield items.sublist(i, i + size > items.length ? items.length : i + size);
  }
}

class DbService {
  static const _dbName = 'toneup_read.db';

  DbService();

  Database? _db;
  final Completer<Database> _initCompleter = Completer<Database>();
  bool _initStarted = false;
  Future<void> _writeChain = Future.value();

  static String sqlVal(dynamic v) {
    if (v == null) return 'NULL';
    if (v is num) return v.isFinite ? v.toString() : 'NULL';
    if (v is bool) return v ? '1' : '0';
    final nul = String.fromCharCode(0);
    final cleaned = v.toString().replaceAll(nul, '').replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
    return "'${cleaned.replaceAll("'", "''")}'";
  }

  Future<Database> get database {
    if (_db != null) return Future.value(_db!);
    if (!_initStarted) {
      _initStarted = true;
      _open().then(_initCompleter.complete).catchError(_initCompleter.completeError);
    }
    return _initCompleter.future;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = '$dir/$_dbName';
    Future<void> runScript(Database db, String script) async {
      for (final stmt in script.split(';')) {
        final s = stmt.trim();
        if (s.isNotEmpty) await db.execute(s);
      }
    }

    final db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        // 全新安装：建表 + 建全部索引（索引不能只放 onUpgrade，否则新安装会完全没有索引）。
        await runScript(db, _schema);
        await runScript(db, _indexes);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 老库升级：先补 v6 的列/表（幂等），再用 IF NOT EXISTS 幂等补齐索引。
        if (oldVersion < 6) await _migrateV6(db);
        if (oldVersion < _dbVersion) await runScript(db, _indexes);
      },
    );
    _db = db;
    return db;
  }

  Future<void> execute(String sql, [List<Object?>? params]) async {
    final db = await database;
    await db.execute(sql, params);
  }

  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    final db = await database;
    return db.rawQuery(sql, params);
  }

  Future<int> insertReturnId(String sql, [List<Object?>? params]) async {
    final db = await database;
    final id = await db.rawInsert(sql, params);
    return id;
  }

  Future<T> _withWriteLock<T>(Future<T> Function() fn) {
    final c = Completer<T>();
    _writeChain = _writeChain.then((_) async {
      try {
        c.complete(await fn());
      } catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  /// v5 → v6：articles 补列（云端元信息）+ 新建 title_zh（标题中译缓存）
  /// + DROP 云端化后废弃的旧表（feeds / 出题备考 / kv）。
  ///
  /// 幂等：先用 `PRAGMA table_info` 看列是否存在再 ALTER，可重复执行；
  /// 旧库若手工跑过部分迁移也不会因「列已存在」报错；DROP 一律 IF EXISTS。
  /// 时间列一律存 epoch 毫秒（接口返回的秒 ×1000）。
  Future<void> _migrateV6(Database db) async {
    const cols = <String, String>{
      'remoteId': 'INTEGER',
      'source': 'TEXT',
      'summary': 'TEXT',
      'publishedAt': 'INTEGER',
      'expiresAt': 'INTEGER',
      'status': 'TEXT',
      'aiVerdict': 'TEXT',
      'remoteFetchedAt': 'INTEGER',
      'cachedAt': 'INTEGER',
    };
    try {
      final info = await db.rawQuery('PRAGMA table_info(articles)');
      final have = info.map((r) => '${r['name']}').toSet();
      for (final e in cols.entries) {
        if (have.contains(e.key)) continue;
        try {
          await db.execute('ALTER TABLE articles ADD COLUMN ${e.key} ${e.value}');
        } catch (_) {
          // 列已存在（并发/重复迁移）等容忍；不阻断后续迁移。
        }
      }
    } catch (_) {
      // PRAGMA 失败时仍尝试逐列补，ALTER 自身的异常会被上面吞掉。
      for (final e in cols.entries) {
        try {
          await db.execute('ALTER TABLE articles ADD COLUMN ${e.key} ${e.value}');
        } catch (_) {}
      }
    }
    await db.execute('CREATE TABLE IF NOT EXISTS title_zh (title TEXT PRIMARY KEY, zh TEXT NOT NULL, at INTEGER)');

    // 云端化后废弃的旧表：抓取/订阅（feeds、feed_items）、出题备考
    // （question_sets、questions、answers、presets、templates、plan_items）
    // 与游戏化键值（kv，见闻/连续/目标等级全落在这里）一次性 DROP。
    // 全部 IF EXISTS，重复执行安全；旧索引随表自动删除。
    for (final t in [
      'feeds',
      'feed_items',
      'question_sets',
      'questions',
      'answers',
      'presets',
      'plan_items',
      'templates',
      'kv',
    ]) {
      await db.execute('DROP TABLE IF EXISTS $t');
    }
  }

  /// 清空「全部数据」= 文章/词典缓存 + 词汇三表。
  Future<void> clearAll() async {
    await _withWriteLock(() async {
      for (final t in ['articles', 'title_zh', 'word_cache', 'vocab_head', 'vocab_occ', 'vocab_sentence']) {
        await execute('DELETE FROM $t');
      }
    });
  }

  /// 清空缓存：文章缓存 + 词典缓存（不动词汇三表）。
  Future<void> clearCache() async {
    await _withWriteLock(() async {
      for (final t in ['articles', 'title_zh', 'word_cache']) {
        await execute('DELETE FROM $t');
      }
    });
  }

  Future<List<dynamic>?> loadCurated(int id) async {
    final rows = await select('SELECT curated_blocks FROM articles WHERE id = ? LIMIT 1', [id]);
    final raw = rows.isEmpty ? null : rows.first['curated_blocks'] as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final bs = jsonDecode(raw);
      return bs is List && bs.isNotEmpty ? bs : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveCurated(int id, List<dynamic> blocks) async {
    await execute('UPDATE articles SET curated_blocks = ? WHERE id = ?', [jsonEncode(blocks), id]);
    return true;
  }

  Future<bool> clearCurated(int id) async {
    await execute('UPDATE articles SET curated_blocks = NULL WHERE id = ?', [id]);
    return true;
  }
}

const String _schema = '''
CREATE TABLE IF NOT EXISTS articles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guid TEXT UNIQUE, title TEXT, author TEXT, sourceUrl TEXT,
  html TEXT, plainText TEXT, blocks TEXT, wordCount INTEGER, capturedAt INTEGER,
  curated_blocks TEXT,
  remoteId INTEGER, source TEXT, summary TEXT,
  publishedAt INTEGER, expiresAt INTEGER, status TEXT,
  aiVerdict TEXT, remoteFetchedAt INTEGER, cachedAt INTEGER
);
CREATE TABLE IF NOT EXISTS word_cache (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  word TEXT, mode TEXT, result TEXT, at INTEGER, lemma TEXT,
  UNIQUE(word, mode)
);
CREATE TABLE IF NOT EXISTS vocab_head (
  head TEXT PRIMARY KEY,
  kind TEXT DEFAULT 'word',
  firstSeen INTEGER, lastSeen INTEGER,
  occCount INTEGER DEFAULT 1,
  family TEXT,
  fsrs_state INTEGER DEFAULT 0,
  fsrs_due INTEGER,
  fsrs_s REAL DEFAULT 0,
  fsrs_d REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS vocab_occ (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  word TEXT, lemma TEXT,
  articleGuid TEXT, articleTitle TEXT, sourceLabel TEXT,
  sentence TEXT, paraIndex INTEGER, tokIndex INTEGER, at INTEGER,
  UNIQUE(word, articleGuid, paraIndex, tokIndex)
);
CREATE TABLE IF NOT EXISTS vocab_sentence (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sentence TEXT UNIQUE,
  articleGuid TEXT, articleTitle TEXT, sourceLabel TEXT,
  paraIndex INTEGER, tokIndex INTEGER, at INTEGER,
  analysis TEXT
);
CREATE TABLE IF NOT EXISTS title_zh (title TEXT PRIMARY KEY, zh TEXT NOT NULL, at INTEGER)
''';

/// 追加的索引：只覆盖确实走全表扫描的热路径（执行计划实测：去掉了全表扫描 + 临时 B 树排序）。
/// - vocab_occ(lemma, at)：词汇页 `GROUP BY lemma`（取最左前缀）与 `WHERE lemma = ? ORDER BY at DESC`
///   （getOccurrence 看某词在哪些文章出现，按时间倒序）。用复合索引同时覆盖这两类查询，
///   不再需要单列 `idx_vocab_occ_lemma`，少维护一个热表（点词每次 INSERT）索引。
/// - vocab_head(lastSeen)：词汇列表 `ORDER BY lastSeen DESC`。
/// - vocab_head(fsrs_due)：复习页 `WHERE fsrs_due <= ? ORDER BY fsrs_due ASC`（高频打开）。
/// - word_cache.lemma：`WHERE word = ? OR lemma = ?` 的 OR 优化需要两侧各有索引
///   （点查 `word+mode` 已由 schema 的 UNIQUE(word,mode) 覆盖，无需额外索引）。
@visibleForTesting
const List<String> dbIndexStatements = [
  'CREATE INDEX IF NOT EXISTS idx_vocab_occ_lemma_at ON vocab_occ(lemma, at)',
  'CREATE INDEX IF NOT EXISTS idx_vocab_head_lastseen ON vocab_head(lastSeen)',
  'CREATE INDEX IF NOT EXISTS idx_vocab_head_fsrsdue ON vocab_head(fsrs_due)',
  'CREATE INDEX IF NOT EXISTS idx_word_cache_lemma ON word_cache(lemma)',
  'CREATE INDEX IF NOT EXISTS idx_vocab_sentence_at ON vocab_sentence(at)',
  // 云端文章缓存：离线兜底列表按 cachedAt 倒序、按 remoteId 点查/回写。
  'CREATE INDEX IF NOT EXISTS idx_articles_cachedat ON articles(cachedAt)',
  'CREATE INDEX IF NOT EXISTS idx_articles_remoteid ON articles(remoteId)',
];

final String _indexes = '${dbIndexStatements.join(';\n')};';

/// 当前数据库版本；每次改 [schema]/[_indexes] 后 +1 并在 [onUpgrade] 里补迁移。
const int _dbVersion = 6;
