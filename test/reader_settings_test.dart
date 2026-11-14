import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/features/reading/widgets/reading_settings_sheet.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/reader_fonts.dart';
import 'package:toneup_read/theme/go_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('字体选项归一', () {
    test('合法 id 原样保留，未知/空回落系统默认', () {
      expect(normalizeReaderFont(null), '');
      expect(normalizeReaderFont(''), '');
      expect(normalizeReaderFont('serif'), 'serif');
      expect(normalizeReaderFont('monospace'), 'monospace');
      expect(normalizeReaderFont(' Songti SC '), '', reason: 'iOS 专属字体名不在选项表里，回落默认');
      expect(normalizeReaderFont('Roboto'), '');
    });

    test('标题字体：未选时衬线（替代 Android 上不存在的 Songti SC）', () {
      expect(Go.titleFont(''), 'serif');
      expect(Go.titleFont('monospace'), 'monospace');
    });
  });

  group('AppConfigService 字体/段距', () {
    test('setReader 持久化 font/paraSpacing，段距 clamp 10..32', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = AppConfigService();
      await cfg.init();

      expect(cfg.readerFont, '', reason: '默认系统字体');
      expect(cfg.paraSpacing, 18, reason: '默认段距与旧版固定值一致');

      await cfg.setReader(font: 'serif', paraSpacing: 40);
      expect(cfg.readerFont, 'serif');
      expect(cfg.paraSpacing, 32, reason: '超出上限要被夹住');

      await cfg.setReader(paraSpacing: 5);
      expect(cfg.paraSpacing, 10, reason: '低于下限要被夹住');

      // 重开读取：mock prefs 里应能还原。
      SharedPreferences.setMockInitialValues({
        'reader_font': 'monospace',
        'reader_paraSpacing': 24.0,
      });
      final cfg2 = AppConfigService();
      await cfg2.init();
      expect(cfg2.readerFont, 'monospace');
      expect(cfg2.paraSpacing, 24);
    });

    test('非法字体写回落到系统默认而不是原样保存', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = AppConfigService();
      await cfg.init();
      await cfg.setReader(font: 'Songti SC');
      expect(cfg.readerFont, '');
    });
  });

  group('ReadingSettingsPanel', () {
    Future<AppConfigService> _cfg() async {
      SharedPreferences.setMockInitialValues({
        'reader_font': 'serif',
        'reader_paraSpacing': 22.0,
      });
      final c = AppConfigService();
      await c.init();
      return c;
    }

    testWidgets('渲染字体三选与段距行，点选回调带正确参数', (tester) async {
      final cfg = await _cfg();
      String? pickedFont;
      double? paraStep;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReadingSettingsPanel(
            cfg: cfg,
            pal: GoReader.night,
            onTheme: (_) {},
            onFontStep: (_) {},
            onLineStep: (_) {},
            onFontFamily: (f) => pickedFont = f,
            onParaStep: (d) => paraStep = d,
            onOpenVoice: () {},
            voiceLabel: 'Aria · 自然女声（美）',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('字体'), findsOneWidget);
      expect(find.text('段距'), findsOneWidget);
      expect(find.text('衬线'), findsOneWidget);
      expect(find.text('等宽'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('22'), findsOneWidget, reason: '段距当前值');

      await tester.tap(find.text('等宽'));
      expect(pickedFont, 'monospace');

      final plus = find.text('＋').last; // 段距行的 ＋（字号/行距行在前）
      await tester.tap(plus);
      expect(paraStep, 2);
    });

    testWidgets('正文文字不套固定高度（textScaler 1.6 不溢出）', (tester) async {
      final cfg = await _cfg();
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReadingSettingsPanel(
              cfg: cfg,
              pal: GoReader.night,
              onTheme: (_) {},
              onFontStep: (_) {},
              onLineStep: (_) {},
              onFontFamily: (_) {},
              onParaStep: (_) {},
              onOpenVoice: () {},
              voiceLabel: 'Aria · 自然女声（美）',
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull);
    });
  });
}
