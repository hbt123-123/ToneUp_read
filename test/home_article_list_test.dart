import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/screens/home_screen.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/remote_article_service.dart';
import 'package:toneup_read/services/translate_service.dart';

import 'fake_db.dart';

/// 首页（云端文章卡片流）渲染回归。
///
/// - 首页有常驻动画（GoPage 的辉光 / 地球自转），**不能用 pumpAndSettle**，一律固定时长 pump。
/// - 列表 / 中译 / 缓存标记全部走 [RemoteArticleService]，用子类假实现替换（不打网络）。
/// - 密钥走 app_config 实际路径：SharedPreferences 明文 key + `init()` 读取
///   （FLUTTER_TEST 下 Keystore 不可用，`_readSecret` 回落到明文 prefs）。
///   没有非空 `articleApiKey` 时首页走「未配置密钥」分支，根本不调 `list()`。

const _zh1 = '气候临界点比想象更近';
const _zh2 = '口袋太阳能的安静崛起';
const _en1 = 'Climate Tipping Points Are Closer Than We Think';
const _en2 = 'The Quiet Rise of Pocket Solar Power';
const _src1 = 'BBC News';
const _src2 = 'The Economist';

const _items = <Map<String, dynamic>>[
  {
    'id': 1,
    'title': _en1,
    'source': _src1,
    'url': 'https://x.test/1',
    'published_at': 1718000000, // 接口返回 epoch 秒
    'word_count': 1234,
  },
  {
    'id': 2,
    'title': _en2,
    'source': _src2,
    'url': 'https://x.test/2',
    'published_at': 1719000000,
    'word_count': 867,
  },
];

/// 只回云端列表形状的假服务：`list` / `titleZhBatch` / `cachedGuids` 覆盖真实实现，
/// 其余（落库 / 翻译 / 网络）在这些路径里根本不会被调到。
class _FakeRemoteArticles extends RemoteArticleService {
  _FakeRemoteArticles(DbService db, AppConfigService cfg)
      : super(db, HttpService(), cfg, TranslateService(LlmService(HttpService(), cfg)));

  int listCalls = 0;

  @override
  Future<Map<String, dynamic>> list({
    String? source,
    String status = 'accepted',
    int page = 1,
    int perPage = 20,
  }) async {
    listCalls++;
    return <String, dynamic>{
      'items': _items,
      'total': _items.length,
      'page': page,
      'perPage': perPage,
    };
  }

  @override
  Future<Map<String, String>> titleZhBatch(List<String> titles) async {
    const all = {_en1: _zh1, _en2: _zh2};
    return {
      for (final t in titles)
        if (all[t] != null) t: all[t]!,
    };
  }

  @override
  Future<Set<String>> cachedGuids() async => <String>{};
}

Future<AppConfigService> _config() async {
  SharedPreferences.setMockInitialValues({
    'article_api_base': 'https://api.test',
    'article_api_key': 'test-article-key', // 明文兜底 key（Keystore 在测试环境不可用）
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

Widget _app(_FakeRemoteArticles fake, AppConfigService cfg, {Widget? home}) {
  return ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(FakeDb()),
      remoteArticleProvider.overrideWithValue(fake),
      appConfigProvider.overrideWith((ref) => cfg),
    ],
    child: MaterialApp(home: home ?? const HomeScreen()),
  );
}

/// 固定视口 + 确定性 pump（避免 pumpAndSettle 撞上常驻动画）。
Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(480, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(app);
  await tester.pump(); // 首帧：postFrameCallback 里发起 _loadFirst
  await tester.pump(const Duration(milliseconds: 20)); // list 返回 → 卡片骨架变实体
  await tester.pump(const Duration(milliseconds: 20)); // titleZhBatch 返回 → 中文标题
}

void main() {
  testWidgets('云端列表：中文标题 / 英文标题 / source 胶囊 / 元信息都渲染', (tester) async {
    final cfg = await _config();
    final fake = _FakeRemoteArticles(DbService(), cfg);
    await _pump(tester, _app(fake, cfg));

    // 卡片首行中译、第二行英文（有中译时才重复展示英文）
    expect(find.text(_zh1), findsOneWidget);
    expect(find.text(_zh2), findsOneWidget);
    expect(find.text(_en1), findsOneWidget);
    expect(find.text(_en2), findsOneWidget);

    // source 胶囊 + 来源 chips：每个来源各出现两次（chips 行 1 + 卡片胶囊 1）
    expect(find.text(_src1), findsNWidgets(2), reason: '来源应同时出现在筛选 chips 与卡片胶囊');
    expect(find.text(_src2), findsNWidgets(2));

    // 元信息里的 word_count（published_at 归一为 MM-dd 拼在后面，用 contains 免时区差异）
    expect(find.textContaining('1234 词'), findsOneWidget);
    expect(find.textContaining('867 词'), findsOneWidget);

    // cachedGuids() 返回空 → 不该出现「已缓存」小标
    expect(find.text('已缓存'), findsNothing);

    expect(fake.listCalls, 1);
    expect(tester.takeException(), isNull, reason: '卡片/胶囊在 480 宽下不应溢出');
  });

  testWidgets('下拉刷新后列表仍渲染且重新拉取第一页', (tester) async {
    final cfg = await _config();
    final fake = _FakeRemoteArticles(DbService(), cfg);
    await _pump(tester, _app(fake, cfg));
    expect(fake.listCalls, 1);

    // RefreshIndicator + AlwaysScrollableScrollPhysics：下拉产生 overscroll → 松手触发 onRefresh
    await tester.drag(find.byType(ListView).first, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(fake.listCalls, greaterThanOrEqualTo(2), reason: '下拉刷新应重新调用 list(page:1)');
    expect(find.text(_zh1), findsOneWidget, reason: '刷新完成后卡片仍渲染');
    expect(find.text(_zh2), findsOneWidget);
    expect(find.text(_src1), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('textScaler 1.6 下首页渲染无异常', (tester) async {
    final cfg = await _config();
    final fake = _FakeRemoteArticles(DbService(), cfg);

    // MediaQuery 放在 home 之下：MaterialApp 提供的 window MediaQuery 作为祖先，
    // 本层 1.6 缩放对 HomeScreen 子树必然生效（不依赖 MaterialApp 是否继承外层 MediaQuery）。
    await _pump(
      tester,
      _app(
        fake,
        cfg,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const HomeScreen(),
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: '大字号下不应有 RenderFlex overflow / 其它异常');
    expect(find.text(_zh1), findsOneWidget);
    expect(find.text(_en1), findsOneWidget);
    expect(find.text(_src1), findsNWidgets(2));
  });
}
