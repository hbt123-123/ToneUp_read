import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/features/reading/widgets/word_card_data.dart';
import 'package:toneup_read/features/reading/widgets/word_popover.dart';
import 'package:toneup_read/features/reading/widgets/word_popup.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/theme/go_tokens.dart';

import 'fake_db.dart';

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

/// /dict 与 /en 的最小合法响应（形状对齐 dict_service_test.dart）。
final Map<String, dynamic> _dictEntry = {
  'found': true,
  'entry': {
    'word': 'hello',
    'phonetic': "hә'lәu",
    'translation': 'n. 喂, 招呼\nint. 喂',
    'definition': 'a greeting expression\nan expression of greeting',
    'pos': 'int',
    'tag': 'cet4',
    'exchange': '',
    'collins': 3,
    'bnc': 2319,
    'frq': 2238,
    'oxford': 1,
  },
  'suggestions': <dynamic>[],
};

final Map<String, dynamic> _dictNotFound = {
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
  'suggestions': <dynamic>[
    {'word': 'xyster', 'phonetic': '', 'translation': 'n. 刮齿刀'},
  ],
};

final List<Map<String, dynamic>> _enArray = [
  {
    'word': 'hello',
    'phonetics': [
      {'text': 'həˈləʊ', 'audio': ''},
    ],
    'meanings': <dynamic>[],
  },
];

Future<AppConfigService> _cfg() async {
  SharedPreferences.setMockInitialValues({
    'gateway_base': 'https://gw.test',
    'gateway_key': 'test-key',
  });
  final c = AppConfigService();
  await c.init();
  return c;
}

ProviderScope _scope(AppConfigService cfg, FakeDb db, Map<String, dynamic> dictReply, Widget child) {
  return ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(db),
      httpProvider.overrideWithValue(HttpService(client: MockClient((req) async {
        if (req.url.path == '/dict') return _ok(dictReply);
        if (req.url.path.startsWith('/en/')) return _ok(_enArray);
        return http.Response('not found', 404);
      }))),
      appConfigProvider.overrideWithValue(cfg),
    ],
    child: child,
  );
}

/// 阅读页测试的文章库：6 段 × 12 词（与 article_token_tap_test 同构，规模小些）。
class _ArtDb extends FakeDb {
  static const _paras = 6;
  static const _wordsPerPara = 12;

  static String paraText(int p) => [for (var i = 0; i < _wordsPerPara; i++) 'word${p}_$i'].join(' ');

  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('curated_blocks')) return [];
    if (sql.contains('plainText, blocks')) {
      final blocks = [for (var p = 0; p < _paras; p++) ArticleBlock(type: 'p', text: paraText(p))];
      return [
        {
          'id': 1,
          'title': 'T',
          'sourceUrl': 'https://x/',
          'wordCount': _paras * _wordsPerPara,
          'plainText': [for (var p = 0; p < _paras; p++) paraText(p)].join('\n\n'),
          'blocks': jsonEncode(blocks.map((b) => b.toJson()).toList()),
        }
      ];
    }
    if (sql.contains('FROM articles')) {
      return [<String, dynamic>{'id': 1, 'title': 'T', 'sourceUrl': 'https://x/', 'wordCount': _paras * _wordsPerPara}];
    }
    return [];
  }
}

/// 第一段第一个词的屏幕中心（复用 article_token_tap_test 的命中取法）。
Offset _firstWordCenter(WidgetTester tester) {
  const indent = '\u2003\u2003';
  final rich = tester
      .widgetList<RichText>(find.byType(RichText))
      .where((w) => w.text.toPlainText().startsWith(indent))
      .first;
  final root = (rich.text as TextSpan).children!.first as TextSpan;
  final wordSpan = root.children!.whereType<TextSpan>().firstWhere((s) => s.recognizer != null);
  final rp = tester.renderObject<RenderParagraph>(find.byWidget(rich));
  final text = root.toPlainText();
  final word = wordSpan.toPlainText()!;
  final start = text.indexOf(word);
  final boxes = rp.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + word.length));
  expect(boxes, isNotEmpty);
  return rp.localToGlobal(boxes.first.toRect().center);
}

Future<void> _pumpArticle(WidgetTester tester, AppConfigService cfg, FakeDb db) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_scope(cfg, db, _dictEntry, const MaterialApp(home: ArticleScreen(articleId: 1))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _teardownTtsTimers(WidgetTester tester) async {
  // TtsService.stop() 内部有 .timeout(4s)，卸载页面后 pump 满 5s 让计时器走完。
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseLookup：词卡/浮窗共用解析', () {
    test('kind=dict → 结构化词卡', () {
      final p = parseLookup(jsonEncode({'kind': 'dict', 'found': true, 'phonetic': 'hel', 'senses': []}));
      expect(p.card, isNotNull);
      expect(p.card!['phonetic'], 'hel');
      expect(p.text, isEmpty);
      expect(p.notFound, isFalse);
    });

    test('kind=text → 纯文本；空 text 视为无结果', () {
      expect(parseLookup(jsonEncode({'kind': 'text', 'text': ' 你好 '})).text, '你好');
      expect(parseLookup(jsonEncode({'kind': 'text', 'text': ''})).text, '');
    });

    test('旧缓存裸文本降级为纯文本', () {
      final p = parseLookup('直接给的一行释义');
      expect(p.card, isNull);
      expect(p.text, '直接给的一行释义');
    });

    test('found=false 可被识别', () {
      expect(parseLookup(jsonEncode(_dictNotFound)).notFound, isTrue);
    });
  });

  group('WordPopover', () {
    testWidgets('展示词/音标/释义，收录后按钮态翻转', (tester) async {
      final cfg = await _cfg();
      var detailed = false;
      await tester.pumpWidget(_scope(
        cfg,
        FakeDb(),
        _dictEntry,
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WordPopover(
                word: 'hello',
                pal: GoReader.night,
                sentence: 'hello world',
                articleGuid: 'g1',
                articleTitle: 'T',
                sourceLabel: 'x',
                paraIndex: 1,
                tokIndex: 2,
                maxHeight: 280,
                onClose: () {},
                onDetail: () => detailed = true,
                onSpeak: (_) async {},
              ),
            ),
          ),
        ),
      ));
      // lookup 走 FakeDb（cache miss）→ MockClient /dict + /en，两次 pump 让 future 落地。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('hello'), findsOneWidget);
      expect(find.textContaining('喂'), findsWidgets, reason: '释义取 senses/zh 的中文');
      expect(find.text("hә'lәu"), findsOneWidget, reason: '音标');

      await tester.tap(find.text('详情'));
      expect(detailed, isTrue, reason: '详情回调触发（完整词卡由页面负责打开）');

      await tester.tap(find.text('加入生词库'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('已收录'), findsOneWidget);
      expect(find.text('已收录到生词库'), findsOneWidget, reason: 'SnackBar 确认');
    });

    testWidgets('found=false 提示词典未收录（引导去完整词卡）', (tester) async {
      final cfg = await _cfg();
      await tester.pumpWidget(_scope(
        cfg,
        FakeDb(),
        _dictNotFound,
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WordPopover(
                word: 'xyzzy',
                pal: GoReader.night,
                sentence: '',
                articleGuid: 'g1',
                articleTitle: 'T',
                sourceLabel: 'x',
                paraIndex: 1,
                tokIndex: 2,
                maxHeight: 280,
                onClose: () {},
                onDetail: () {},
                onSpeak: (_) async {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('词典未收录'), findsOneWidget);
    });
  });

  group('阅读页点词 → 就地浮窗', () {
    testWidgets('点词弹就地浮窗（完整词卡不再直接弹出），点 × 收起', (tester) async {
      final cfg = await _cfg();
      await _pumpArticle(tester, cfg, _ArtDb());

      await tester.tapAt(_firstWordCenter(tester));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.byType(WordPopover), findsOneWidget, reason: '点词应弹就地浮窗');
      expect(find.byType(WordCardSheet), findsNothing, reason: '完整词卡只在点「详情」后出现');
      expect(find.textContaining('word0_0'), findsWidgets);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byType(WordPopover), findsNothing, reason: '点 × 收起浮窗');

      await _teardownTtsTimers(tester);
    });

    testWidgets('浮窗「详情」打开完整词卡；滚动正文收起浮窗', (tester) async {
      final cfg = await _cfg();
      await _pumpArticle(tester, cfg, _ArtDb());

      await tester.tapAt(_firstWordCenter(tester));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byType(WordPopover), findsOneWidget);

      await tester.tap(find.text('详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byType(WordCardSheet), findsOneWidget, reason: '详情 → 完整词卡');

      // 关掉词卡弹层（词卡的 × 是文本按钮），再验证滚动收起浮窗。
      await tester.tap(find.text('×'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(WordCardSheet), findsNothing);

      await tester.fling(find.byType(SingleChildScrollView).first, const Offset(0, -120), 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byType(WordPopover), findsNothing, reason: '正文一滚，锚定失效，浮窗应立即收起');

      await _teardownTtsTimers(tester);
    });
  });
}
