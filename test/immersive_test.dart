import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/features/reading/widgets/reading_app_bar.dart';
import 'package:toneup_read/features/reading/widgets/word_popover.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/http_service.dart';

import 'fake_db.dart';

const _paras = 6;
const _wordsPerPara = 12;

String _paraText(int p) => [for (var i = 0; i < _wordsPerPara; i++) 'word${p}_$i'].join(' ');

class _ArtDb extends FakeDb {
  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async {
    if (sql.contains('curated_blocks')) return [];
    if (sql.contains('plainText, blocks')) {
      final blocks = [for (var p = 0; p < _paras; p++) ArticleBlock(type: 'p', text: _paraText(p))];
      return [
        {
          'id': 1,
          'title': 'T',
          'sourceUrl': 'https://x/',
          'wordCount': _paras * _wordsPerPara,
          'plainText': [for (var p = 0; p < _paras; p++) _paraText(p)].join('\n\n'),
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

Future<AppConfigService> _cfg() async {
  SharedPreferences.setMockInitialValues({
    'gateway_base': 'https://gw.test',
    'gateway_key': 'test-key',
  });
  final c = AppConfigService();
  await c.init();
  return c;
}

Widget _wrap(AppConfigService cfg, FakeDb db, Widget child) => ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        // 词内点击会弹浮窗并查词：给 MockClient 兜住，测试不打真实网络。
        httpProvider.overrideWithValue(HttpService(client: MockClient((req) async {
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }))),
        appConfigProvider.overrideWithValue(cfg),
      ],
      child: child,
    );

/// 段内某个 span 的屏幕中心：词 span（带 recognizer）或空白 span（不带）。
Offset _spanCenter(WidgetTester tester, {required bool word}) {
  const indent = '\u2003\u2003';
  final rich = tester
      .widgetList<RichText>(find.byType(RichText))
      .where((w) => w.text.toPlainText().startsWith(indent))
      .first;
  final root = (rich.text as TextSpan).children!.first as TextSpan;
  final span = root.children!.whereType<TextSpan>().firstWhere((s) => (s.recognizer != null) == word);
  final text = root.toPlainText();
  final piece = span.toPlainText()!;
  final start = text.indexOf(piece);
  final rp = tester.renderObject<RenderParagraph>(find.byWidget(rich));
  final boxes = rp.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + piece.length));
  expect(boxes, isNotEmpty);
  return rp.localToGlobal(boxes.first.toRect().center);
}

Future<void> _pump(WidgetTester tester, AppConfigService cfg) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(cfg, _ArtDb(), const MaterialApp(home: ArticleScreen(articleId: 1))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _teardownTtsTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点正文空白切换沉浸模式：顶栏收起/恢复，正文不受影响', (tester) async {
    final cfg = await _cfg();
    await _pump(tester, cfg);

    expect(find.byType(ReadingAppBar), findsOneWidget);

    // 首行缩进属于「非词」区域：单击 → 收起顶栏（进入沉浸）。
    await tester.tapAt(_spanCenter(tester, word: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReadingAppBar), findsNothing, reason: '沉浸模式下顶栏应收起');

    // 再点一次空白 → 恢复。
    await tester.tapAt(_spanCenter(tester, word: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReadingAppBar), findsOneWidget);

    // 正文仍在（段落没被沉浸切换破坏）。
    final richCount = tester.widgetList<RichText>(find.byType(RichText)).length;
    expect(richCount, greaterThan(0));

    await _teardownTtsTimers(tester);
  });

  testWidgets('词内点击不切换沉浸（弹就地浮窗），长按选区不受影响', (tester) async {
    final cfg = await _cfg();
    await _pump(tester, cfg);

    await tester.tapAt(_spanCenter(tester, word: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(ReadingAppBar), findsOneWidget, reason: '点词不应触发沉浸切换');
    expect(find.byType(WordPopover), findsOneWidget, reason: '点词照常弹词卡浮窗');

    await _teardownTtsTimers(tester);
  });

  testWidgets('进入沉浸时顺手收起设置面板', (tester) async {
    final cfg = await _cfg();
    await _pump(tester, cfg);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    expect(find.text('阅读外观'), findsOneWidget, reason: '设置面板已展开');

    await tester.tapAt(_spanCenter(tester, word: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReadingAppBar), findsNothing);
    expect(find.text('阅读外观'), findsNothing, reason: '顶栏收起时设置面板应一并收起');

    await tester.tapAt(_spanCenter(tester, word: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('阅读外观'), findsNothing, reason: '恢复顶栏时面板不自动展开');
    expect(find.byType(ReadingAppBar), findsOneWidget);

    await _teardownTtsTimers(tester);
  });
}
