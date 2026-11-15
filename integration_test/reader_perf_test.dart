import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/db_service.dart';

/// 阅读器长文性能基准：回答「SingleChildScrollView + Column 全量构建在超长文章下是否卡顿」。
///
/// 三档种子文章（纯 'p' 块——线上 RemoteArticleService._blocksOf 只产文本段，无图片，图片不是当前变量）：
/// - S  基线：  500 词 / 10 段（当前典型规模）
/// - M  长文： 4000 词 / 80 段
/// - XL 极端：16000 词 / 320 段（模拟整章转载，最坏情况）
///
/// 每档三组指标（stdout 打 READER_PERF 行，末尾 reportData 回传 driver 落盘 build/perf_results.json）：
/// - load：独立计时 DB SELECT 与 blocks 解析（定位瓶颈用；这条 SELECT 会预热页缓存，
///   open 阶段的 DB 耗时因此偏乐观，只作参考）。
/// - open：pump ArticleScreen 到正文首帧（「— 全文完 —」出现）的总耗时 + 期间最大 UI 帧耗时。
///   首帧 build 含全篇分词（syncTokens）+ 全部段落构建 + 布局；轮询步长 ~20ms，计时粒度受此限制。
/// - scroll：交替方向 fling 8 轮的 FrameTiming 统计（build/raster avg/p90/max + >16.7ms 丢帧数）。
///
/// 决策标准（60Hz，帧预算 16.7ms）：
/// - 首帧 < 300ms 且滚动 p90 ≤ 16.7ms → 不动架构，记录基线，议题关闭；
/// - 首帧 300-800ms 或滚动 p90 16.7-32ms → 观察项，真实长文出现时复测；
/// - 首帧 > 800ms 或滚动 p90 > 32ms / 持续掉帧 → 再立项优化
///   （load/解析超标 → tokenize isolate 化；首帧 build 超标 → 懒加载列表）。
///
/// 只能在真机/模拟器跑（真 sqflite）：
/// flutter drive --driver=test_driver/perf_driver.dart --target=integration_test/reader_perf_test.dart -d <device>
const String _seedPrefix = 'zzperf-reader-';

/// 每档统一 50 词/段，规模只变段数。
const int _wordsPerPara = 50;
const Map<String, int> _sizes = {'S': 10, 'M': 80, 'XL': 320};

/// 常用词表：拼出的段落全是真实词形 token（[A-Za-z]+），完整走分词 → TextSpan → recognizer 路径。
const List<String> _bank = [
  'the', 'of', 'and', 'to', 'in', 'a', 'is', 'that', 'for', 'it', 'with', 'as',
  'was', 'on', 'are', 'by', 'this', 'be', 'from', 'or', 'an', 'which', 'one',
  'had', 'not', 'but', 'what', 'all', 'were', 'when', 'we', 'there', 'can',
  'been', 'more', 'if', 'will', 'would', 'about', 'their', 'other', 'new',
  'some', 'could', 'time', 'these', 'two', 'may', 'then', 'do', 'first', 'any',
  'my', 'now', 'such', 'like', 'our', 'over', 'man', 'me', 'even', 'most',
  'after', 'also', 'made', 'many', 'before', 'must', 'through', 'years',
  'where', 'much', 'your', 'way', 'well', 'down', 'should', 'because', 'each',
  'just', 'those', 'people', 'how', 'too', 'little', 'state', 'good', 'very',
  'make', 'world', 'still', 'own', 'see', 'men', 'work', 'long', 'get', 'here',
  'between', 'both', 'life', 'being', 'under', 'never', 'day', 'same',
  'another', 'know', 'while', 'last', 'might', 'great', 'old', 'come', 'right',
  'used', 'take', 'three', 'water', 'house', 'point', 'large', 'small',
  'early', 'young', 'important', 'few', 'public', 'bad', 'open', 'think',
];

double _avg(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
double _pct(List<double> v, double p) =>
    v.isEmpty ? 0 : v[(v.length * p).toInt().clamp(0, v.length - 1)];

/// 确定性伪随机拼段：步长（13/7）与词表长度互质，段落间词序不重复。
String _paraText(int p) =>
    [for (var i = 0; i < _wordsPerPara; i++) _bank[(p * 13 + i * 7) % _bank.length]].join(' ');

/// 直插真 sqflite（模式同 perf_test.dart），返回自增 id；INSERT OR REPLACE 保证重复跑幂等。
Future<int> _seedArticle(DbService db, String guid, int paras) async {
  final parasText = [for (var p = 0; p < paras; p++) _paraText(p)];
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.execute(
    'INSERT OR REPLACE INTO articles (guid, title, sourceUrl, plainText, blocks, wordCount, status, publishedAt, cachedAt) VALUES (?,?,?,?,?,?,?,?,?)',
    [
      guid,
      'Reader Perf ${guid.substring(_seedPrefix.length)}',
      'zzperf://reader',
      parasText.join('\n\n'),
      jsonEncode([for (var p = 0; p < paras; p++) {'type': 'p', 'text': parasText[p]}]),
      paras * _wordsPerPara,
      'cached',
      now,
      now,
    ],
  );
  final rows = await db.select('SELECT id FROM articles WHERE guid = ?', [guid]);
  return (rows.first['id'] as num).toInt();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final db = DbService();
  final ids = <String, int>{};
  final report = <String, Object?>{};

  setUpAll(() async {
    await db.database;
    for (final e in _sizes.entries) {
      ids[e.key] = await _seedArticle(db, '$_seedPrefix${e.key}', e.value);
    }
  });

  tearDownAll(() async {
    await db.execute("DELETE FROM articles WHERE guid LIKE '$_seedPrefix%'");
  });

  testWidgets('阅读器 S/M/XL 三档：open 首帧 + 滚动帧率', (tester) async {
    // 与 ReadingController.load() 完全一致的列清单，保证 SELECT 计时有代表性。
    const cols =
        'id, title, sourceUrl, wordCount, plainText, blocks, source, publishedAt, expiresAt, cachedAt, status, summary, remoteId';

    // 任一档失败也把已有数据回传 driver（addTearDown 在测试失败后仍会执行；
    // perf_driver.dart 的 responseDataCallback 据此落盘 build/perf_results.json）。
    // 无 driver 接收端（如直接 flutter test integration_test/...）时忽略，stdout 已有数据。
    addTearDown(() async {
      try {
        await binding.reportData(<String, Object?>{
          'reader_perf': report,
          'decision_60hz': 'first_frame<300ms & scroll_p90<=16.7ms -> keep; first_frame>800ms or p90>32ms -> optimize',
        });
      } catch (_) {}
    });

    for (final size in _sizes.keys) {
      final paras = _sizes[size]!;
      final id = ids[size]!;

      // ---- 1) load 阶段独立计时：DB SELECT + blocks 解析 ----
      final swDb = Stopwatch()..start();
      final rows = await db.select('SELECT $cols FROM articles WHERE id = ?', [id]);
      swDb.stop();
      final raw = (rows.first['blocks'] as String?) ?? '';
      final swJson = Stopwatch()..start();
      final parsed = raw.isEmpty
          ? <ArticleBlock>[]
          : (jsonDecode(raw) as List).map((e) => ArticleBlock.fromJson(e as Map<String, dynamic>)).toList();
      swJson.stop();
      expect(parsed.length, paras, reason: '种子 blocks 应完整');

      // ---- 2) open：从 pumpWidget 到正文首帧 ----
      final rssBefore = ProcessInfo.currentRss ~/ 1024;
      final openFrames = <FrameTiming>[];
      void onOpen(List<FrameTiming> t) => openFrames.addAll(t);
      WidgetsBinding.instance.addTimingsCallback(onOpen);
      final swOpen = Stopwatch()..start();
      await tester.pumpWidget(ProviderScope(
        overrides: [dbProvider.overrideWithValue(db)],
        child: MaterialApp(home: ArticleScreen(articleId: id)),
      ));
      // 「— 全文完 —」只有正文渲染后才出现；轮询给真实 DB I/O 让出事件循环（live binding，无 fake async）。
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (find.textContaining('全文完').evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 16));
      }
      swOpen.stop();
      expect(find.textContaining('全文完'), findsWidgets, reason: '正文应渲染出来；若超时先检查加载是否出错');
      // FrameTiming 回调异步批量送达：渲染/等待一拍再收，确保最后几帧进账。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 16));
      WidgetsBinding.instance.removeTimingsCallback(onOpen);
      final openBuild = openFrames.map((t) => t.buildDuration.inMicroseconds / 1000.0).toList()..sort();
      final openRaster = openFrames.map((t) => t.rasterDuration.inMicroseconds / 1000.0).toList()..sort();

      // ---- 3) scroll：交替方向 8 轮（小文章不会一直顶在底部） ----
      final frames = <FrameTiming>[];
      void onScroll(List<FrameTiming> t) => frames.addAll(t);
      WidgetsBinding.instance.addTimingsCallback(onScroll);
      for (var round = 0; round < 8; round++) {
        final dir = round.isEven ? const Offset(0, -900) : const Offset(0, 900);
        await tester.fling(find.byType(Scrollable).first, dir, 3000);
        for (var f = 0; f < 25; f++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 16));
      WidgetsBinding.instance.removeTimingsCallback(onScroll);
      final build = frames.map((t) => t.buildDuration.inMicroseconds / 1000.0).toList()..sort();
      final raster = frames.map((t) => t.rasterDuration.inMicroseconds / 1000.0).toList()..sort();

      final rssOpen = ProcessInfo.currentRss ~/ 1024;

      debugPrint('READER_PERF size=$size words=${paras * _wordsPerPara} paras=$paras '
          'db=${swDb.elapsedMilliseconds}ms json=${swJson.elapsedMilliseconds}ms '
          'first_frame=${swOpen.elapsedMilliseconds}ms '
          'open_max_build=${openBuild.isEmpty ? 0 : openBuild.last.toStringAsFixed(1)}ms '
          'open_max_raster=${openRaster.isEmpty ? 0 : openRaster.last.toStringAsFixed(1)}ms '
          'rss_kb before=$rssBefore open=$rssOpen');
      debugPrint('READER_PERF_SCROLL size=$size frames=${frames.length} '
          'build avg=${_avg(build).toStringAsFixed(2)} p90=${_pct(build, 0.9).toStringAsFixed(2)} max=${build.isEmpty ? 0 : build.last.toStringAsFixed(1)}ms | '
          'raster avg=${_avg(raster).toStringAsFixed(2)} p90=${_pct(raster, 0.9).toStringAsFixed(2)} max=${raster.isEmpty ? 0 : raster.last.toStringAsFixed(1)}ms | '
          'missed(>16.7ms) build=${build.where((x) => x > 16.67).length} raster=${raster.where((x) => x > 16.67).length}');

      report[size] = <String, Object?>{
        'words': paras * _wordsPerPara,
        'paras': paras,
        'db_ms': swDb.elapsedMilliseconds,
        'json_ms': swJson.elapsedMilliseconds,
        'first_frame_ms': swOpen.elapsedMilliseconds,
        'open_max_build_ms': openBuild.isEmpty ? 0 : openBuild.last,
        'open_max_raster_ms': openRaster.isEmpty ? 0 : openRaster.last,
        'rss_kb_before': rssBefore,
        'rss_kb_open': rssOpen,
        'scroll': <String, Object?>{
          'frames': frames.length,
          'build_avg_ms': _avg(build),
          'build_p90_ms': _pct(build, 0.9),
          'build_max_ms': build.isEmpty ? 0 : build.last,
          'raster_avg_ms': _avg(raster),
          'raster_p90_ms': _pct(raster, 0.9),
          'raster_max_ms': raster.isEmpty ? 0 : raster.last,
          'missed_build_gt16_7ms': build.where((x) => x > 16.67).length,
          'missed_raster_gt16_7ms': raster.where((x) => x > 16.67).length,
        },
      };

      // 收尾：卸载页面。dispose 会触发 TtsService.stop()（内部有 4s 超时计时器），
      // 等真实 5 秒让它走完再进入下一档；live binding 下 Future.delayed 即真实等待。
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
