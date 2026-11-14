import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/features/home/screens/home_screen.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/remote_article_service.dart';
import 'package:toneup_read/services/translate_service.dart';

import 'fake_db.dart';

/// 首页「最近阅读」卡回归：recentlyRead 有行 → 卡片渲染（标题/进度/相对时间）；
/// 无行 → 整张卡不出现。约定同 home_article_list_test（禁 pumpAndSettle、固定视口）。

const _en1 = 'Climate Tipping Points Are Closer Than We Think';
const _zh1 = '气候临界点比想象更近';

/// DB 行（recentlyRead 返回形状）：camelCase 列 + epoch 毫秒。
final _readRow = <String, dynamic>{
  'id': 5,
  'guid': 'https://x.test/1',
  'sourceUrl': 'https://x.test/1',
  'title': _en1,
  'source': 'BBC News',
  'wordCount': 1234,
  'publishedAt': 1718000000000,
  'lastOpenedAt': DateTime.now().millisecondsSinceEpoch, // 今天
  'lastPara': 3,
  'readProgress': 0.42,
  'aiVerdict': null,
};

class _FakeRemoteArticles extends RemoteArticleService {
  _FakeRemoteArticles(this.rows, AppConfigService cfg)
      : super(DbService(), HttpService(), cfg, TranslateService(LlmService(HttpService(), cfg)));

  final List<Map<String, dynamic>> rows;

  @override
  Future<Map<String, dynamic>> list({String? source, String status = 'accepted', int page = 1, int perPage = 20}) async =>
      <String, dynamic>{'items': const [], 'total': 0, 'page': page, 'perPage': perPage};

  @override
  Future<Map<String, String>> titleZhBatch(List<String> titles) async =>
      titles.contains(_en1) ? {_en1: _zh1} : {};

  @override
  Future<Set<String>> cachedGuids() async => <String>{};

  @override
  Future<List<Map<String, dynamic>>> recentlyRead(int limit) async => rows.take(limit).toList();

  @override
  Future<List<Map<String, dynamic>>> searchArticles(String query, {int limit = 50}) async => const [];

  @override
  Future<Map<int, List<String>>> ensureTopics(List<Map<String, dynamic>> items, {int maxFetch = 12}) async => const {};
}

Future<AppConfigService> _config() async {
  SharedPreferences.setMockInitialValues({
    'article_api_base': 'https://api.test',
    'article_api_key': 'test-article-key',
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

Future<void> _pump(WidgetTester tester, RemoteArticleService fake, AppConfigService cfg) async {
  tester.view.physicalSize = const Size(480, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(FakeDb()),
      remoteArticleProvider.overrideWithValue(fake),
      appConfigProvider.overrideWith((ref) => cfg),
    ],
    child: MaterialApp(home: const HomeScreen()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  testWidgets('有最近阅读：卡片渲染中文标题 / 进度百分比 / 相对时间', (tester) async {
    final cfg = await _config();
    await _pump(tester, _FakeRemoteArticles([_readRow], cfg), cfg);

    expect(find.text(_zh1), findsOneWidget);
    expect(find.textContaining('已读 42%'), findsOneWidget);
    expect(find.textContaining('今天'), findsOneWidget);
    // 进度条组件在树上（GoProgress 内部 FractionallySizedBox）。
    expect(find.byType(FractionallySizedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有阅读记录：不渲染「最近阅读」卡', (tester) async {
    final cfg = await _config();
    await _pump(tester, _FakeRemoteArticles(const [], cfg), cfg);

    expect(find.text(_zh1), findsNothing);
    expect(find.textContaining('已读'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
