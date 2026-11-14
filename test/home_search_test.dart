import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/features/home/screens/home_search_screen.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/remote_article_service.dart';
import 'package:toneup_read/services/translate_service.dart';

import 'fake_db.dart';

/// 首页搜索页回归：空查询引导态 / 命中渲染结果卡 / 无结果空态。
/// 搜索走 searchArticles（本地库 LIKE），fake 直接返回 DB 行形状。

const _en1 = 'Climate Tipping Points Are Closer Than We Think';
const _zh1 = '气候临界点比想象更近';

/// DB 行（searchArticles 返回形状）。
final _hitRow = <String, dynamic>{
  'id': 5,
  'guid': 'https://x.test/1',
  'sourceUrl': 'https://x.test/1',
  'title': _en1,
  'source': 'BBC News',
  'wordCount': 1234,
  'publishedAt': 1718000000000,
  'aiVerdict': null,
};

class _FakeRemoteArticles extends RemoteArticleService {
  _FakeRemoteArticles(this.hits, AppConfigService cfg)
      : super(DbService(), HttpService(), cfg, TranslateService(LlmService(HttpService(), cfg)));

  final List<Map<String, dynamic>> hits;
  int searchCalls = 0;

  @override
  Future<Map<String, dynamic>> list({String? source, String status = 'accepted', int page = 1, int perPage = 20}) async =>
      <String, dynamic>{'items': const [], 'total': 0, 'page': page, 'perPage': perPage};

  @override
  Future<List<Map<String, dynamic>>> searchArticles(String query, {int limit = 50}) async {
    searchCalls++;
    if (query.toLowerCase().contains('climate')) return [Map<String, dynamic>.of(hits.first)];
    return const [];
  }

  @override
  Future<Map<String, String>> titleZhBatch(List<String> titles) async =>
      titles.contains(_en1) ? {_en1: _zh1} : {};

  @override
  Future<Set<String>> cachedGuids() async => <String>{};
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

Future<void> _pump(WidgetTester tester, _FakeRemoteArticles fake, AppConfigService cfg) async {
  tester.view.physicalSize = const Size(480, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(FakeDb()),
      remoteArticleProvider.overrideWithValue(fake),
      appConfigProvider.overrideWith((ref) => cfg),
    ],
    child: const MaterialApp(home: HomeSearchScreen()),
  ));
  await tester.pump(); // 首帧 + postFrame 自动聚焦
}

void main() {
  testWidgets('空查询显示引导态，输入命中后渲染结果卡（含中译）', (tester) async {
    final cfg = await _config();
    final fake = _FakeRemoteArticles([_hitRow], cfg);
    await _pump(tester, fake, cfg);

    // 引导态。
    expect(find.text('搜索文章'), findsOneWidget);
    expect(fake.searchCalls, 0);

    // 输入关键词 → 300ms 防抖触发查询。
    await tester.enterText(find.byType(TextField), 'climate');
    await tester.pump(const Duration(milliseconds: 350)); // 防抖到期
    await tester.pump(const Duration(milliseconds: 20)); // searchArticles 返回
    await tester.pump(const Duration(milliseconds: 20)); // titleZhBatch 返回

    expect(fake.searchCalls, 1);
    expect(find.text(_zh1), findsOneWidget);
    expect(find.textContaining('1234 词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无结果时显示空态', (tester) async {
    final cfg = await _config();
    final fake = _FakeRemoteArticles([_hitRow], cfg);
    await _pump(tester, fake, cfg);

    await tester.enterText(find.byType(TextField), 'solar');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    expect(fake.searchCalls, 1);
    expect(find.text('没有找到相关文章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
