import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/screens/article_screen.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';

import 'fake_db.dart';

/// 词卡短语分支：查询文本含空格 → 只走网关 `POST …/v1/chat/completions`，
/// **绝不打 `/dict`、`/en/`**，词卡头部出现「短语」角标。
///
/// 触发路径完全走真实交互：长按正文取整句（`_sentenceAround`，段内无句末标点
/// 时取整段）→ 底部选区条 `_selBar` → 点「查询」→ `_WordCardDialog` 词卡。

const _para = 'small teams ship bold ideas faster than committees expect';

/// 正文假库：结构照抄 article_token_tap_test 的命中范式。
class _ArtDb extends FakeDb {
  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('curated_blocks')) return [];
    // 正文是一次查询取齐 plainText/blocks
    if (sql.contains('plainText, blocks')) {
      final blocks = [ArticleBlock(type: 'p', text: _para)];
      return [
        {
          'id': 1,
          'title': 'T',
          'sourceUrl': 'https://x.test/',
          'wordCount': 9,
          'plainText': _para,
          'blocks': jsonEncode(blocks.map((b) => b.toJson()).toList()),
        },
      ];
    }
    if (sql.contains('FROM articles')) {
      return [<String, dynamic>{'id': 1, 'title': 'T', 'sourceUrl': 'https://x.test/', 'wordCount': 9}];
    }
    return [];
  }

  @override
  Future<int> insertReturnId(String sql, [List<Object?>? params]) async => 1;
}

Future<AppConfigService> _config() async {
  SharedPreferences.setMockInitialValues({
    'gateway_base': 'https://gw.test',
    'gateway_key': 'test-gateway-key', // 明文兜底 key（Keystore 在测试环境不可用）
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

const _indent = '  ';

/// 只有正文段带首行缩进，据此把段落从其它文本里区分出来（同 article_token_tap_test）。
List<RichText> _paragraphs(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .where((w) => w.text.toPlainText().startsWith(_indent))
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('含空格的查询走网关 chat 分支，不调 /dict 与 /en', (tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final reqs = <http.Request>[];
    final cfg = await _config();
    final client = MockClient((req) async {
      reqs.add(req);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': 'gloss of the phrase\nfull translation of the sentence',
              }
            },
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(_ArtDb()),
        appConfigProvider.overrideWith((ref) => cfg),
        httpProvider.overrideWithValue(HttpService(client: client)),
      ],
      child: const MaterialApp(home: ArticleScreen(articleId: 1)),
    ));
    // 不用 pumpAndSettle：页面有常驻动画（辉光/Spinner）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // ---- 长按正文第一个词：整段无句末标点 → 选中整段（含空格）→ 出选区条 ----
    final first = _paragraphs(tester).first;
    final root = (first.text as TextSpan).children!.first as TextSpan;
    final ranges = <({int start, int end})>[];
    var off = 0;
    for (final s in root.children!) {
      final len = s.toPlainText().length;
      if (s is TextSpan && s.recognizer != null) ranges.add((start: off, end: off + len));
      off += len;
    }
    expect(ranges, isNotEmpty, reason: '词 span 应挂上点击识别器');

    final rp = tester.renderObject<RenderParagraph>(find.byWidget(first));
    final boxes =
        rp.getBoxesForSelection(TextSelection(baseOffset: ranges.first.start, extentOffset: ranges.first.end));
    expect(boxes, isNotEmpty);
    await tester.longPressAt(rp.localToGlobal(boxes.first.toRect().center));
    await tester.pump();

    expect(find.text('查询'), findsOneWidget, reason: '长按后应出现选区条 _selBar');

    // ---- 点「查询」：cleanQueryText 保留空格 → 词卡走短语分支 ----
    await tester.tap(find.text('查询'));
    await tester.pump(); // recordOccurrence 微任务链 + 弹层入场
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300)); // chat 返回 → setState

    // 词卡头部「短语」角标（_isPhrase 判定 _q 含空白）
    expect(find.text('短语'), findsOneWidget);
    expect(find.text('查询中…'), findsNothing, reason: '查询应已完成');
    expect(find.text('AI 释义'), findsOneWidget, reason: '短语卡片内容区（chat 成功返回）');
    expect(
      find.text('gloss of the phrase\nfull translation of the sentence'),
      findsOneWidget,
      reason: '网关返回的两行释义应渲染到卡片',
    );

    // ---- 请求断言：只允许 chat，不允许 /dict 或 /en/ ----
    final chat = reqs.where((r) => r.method == 'POST' && r.url.path.endsWith('/v1/chat/completions')).toList();
    expect(chat, hasLength(1), reason: '短语查询应恰好打一次网关 chat: ${reqs.map((r) => '${r.method} ${r.url}')}');
    expect(reqs.any((r) => r.url.path.contains('/dict')), isFalse, reason: '短语不应调 /dict');
    expect(reqs.any((r) => r.url.path.contains('/en/')), isFalse, reason: '短语不应调 /en/<word>');
    expect(reqs.every((r) => r.url.host == 'gw.test'), isTrue);

    final body = jsonDecode(chat.single.body) as Map<String, dynamic>;
    final messages = body['messages'] as List;
    expect(messages.first['role'], 'system');
    expect('${messages.last['content']}', contains('英文短语：'));
    expect('${messages.last['content']}', contains('small teams'), reason: 'user prompt 应带上整段查询文本');

    // 卸载页面并把挂起的计时器跑干净（TtsService.stop() 内部有 .timeout(4s)）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
