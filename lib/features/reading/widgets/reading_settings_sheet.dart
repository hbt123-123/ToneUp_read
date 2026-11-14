import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/reader_fonts.dart';
import 'package:toneup_read/services/tts_voices.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 语速档位：与 AppConfigService.setTts 的 clamp(0.7, 1.3) 对齐。
const List<double> kReadingTtsSpeeds = [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3];

/// 顶栏下的内联阅读设置面板：外观 / 字体 / 字号 / 行距 / 段距 / 朗读音色。
/// 所有改动走 appConfig.setReader，notify 后同帧生效，不重载文章。
class ReadingSettingsPanel extends StatelessWidget {
  final AppConfigService cfg;
  final GoReaderPalette pal;
  final ValueChanged<String> onTheme;
  final ValueChanged<int> onFontStep;
  final ValueChanged<double> onLineStep;
  final ValueChanged<String> onFontFamily;
  final ValueChanged<double> onParaStep;
  final VoidCallback onOpenVoice;
  final String voiceLabel;

  const ReadingSettingsPanel({
    super.key,
    required this.cfg,
    required this.pal,
    required this.onTheme,
    required this.onFontStep,
    required this.onLineStep,
    required this.onFontFamily,
    required this.onParaStep,
    required this.onOpenVoice,
    required this.voiceLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: pal.surface, border: Border(bottom: BorderSide(color: pal.divider, width: 0.5))),
      padding: const EdgeInsets.symmetric(vertical: Go.sp2),
      child: Column(
        children: [
          _row('阅读外观', Row(mainAxisSize: MainAxisSize.min, children: [
            _themeChip('夜读', cfg.readerTheme != 'paper', () => onTheme('night')),
            const SizedBox(width: Go.sp3),
            _themeChip('纸色', cfg.readerTheme == 'paper', () => onTheme('paper')),
          ])),
          _row('字体', Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < kReaderFonts.length; i++) ...[
              if (i > 0) const SizedBox(width: Go.sp3),
              _themeChip(kReaderFonts[i][1], cfg.readerFont == kReaderFonts[i].first, () => onFontFamily(kReaderFonts[i].first)),
            ],
          ])),
          _row('字号', Row(mainAxisSize: MainAxisSize.min, children: [
            _step('A−', () => onFontStep(-1)),
            SizedBox(width: Go.r(80), child: Text(cfg.fontSize.toStringAsFixed(0), textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary))),
            _step('A＋', () => onFontStep(1)),
          ])),
          _row('行距', Row(mainAxisSize: MainAxisSize.min, children: [
            _step('−', () => onLineStep(-0.1)),
            SizedBox(width: Go.r(80), child: Text(cfg.lineHeight.toStringAsFixed(1), textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary))),
            _step('＋', () => onLineStep(0.1)),
          ])),
          _row('段距', Row(mainAxisSize: MainAxisSize.min, children: [
            _step('−', () => onParaStep(-2)),
            SizedBox(width: Go.r(80), child: Text(cfg.paraSpacing.toStringAsFixed(0), textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary))),
            _step('＋', () => onParaStep(2)),
          ])),
          _row(
            '朗读音色',
            GestureDetector(
              onTap: onOpenVoice,
              behavior: HitTestBehavior.opaque,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(voiceLabel, style: TextStyle(fontSize: Go.fsBodySm, color: pal.ink)),
                const SizedBox(width: Go.sp1),
                Icon(Icons.chevron_right, size: 18, color: pal.meta),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp4),
            child: Align(alignment: Alignment.centerLeft, child: Text('单击查词 · 长按整句 · 工具栏「选择」可点选多词查询或翻译 · 朗读按钮可播放全文', style: TextStyle(fontSize: Go.fsMeta, color: pal.meta))),
          ),
        ],
      ),
    );
  }

  /// 夜读/纸色切换胶囊：选中项带对勾 + 强调色描边，未选中项融入面板。
  Widget _themeChip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
          decoration: BoxDecoration(
            color: on ? pal.accent.withValues(alpha: pal.isNight ? 0.18 : 0.12) : pal.card,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: Border.all(color: on ? pal.accent : pal.divider, width: on ? 1 : 0.5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (on) ...[
              Icon(Icons.check, size: 14, color: pal.accent),
              const SizedBox(width: Go.sp1),
            ],
            Text(label, style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: on ? pal.accent : pal.meta)),
          ]),
        ),
      );

  Widget _row(String label, Widget child) => Container(
        margin: const EdgeInsets.symmetric(horizontal: Go.sp6),
        padding: const EdgeInsets.symmetric(vertical: Go.sp4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.divider, width: 0.5))),
        child: Row(
          children: [
            // minWidth 而非固定宽：「阅读外观」四个字比旧的 48dp 标签盒宽，固定宽会折行。
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: Go.r(96)),
              child: Text(label, style: TextStyle(fontSize: Go.fsBodySm, color: pal.ink)),
            ),
            const Spacer(),
            child,
          ],
        ),
      );

  Widget _step(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minWidth: Go.r(64)),
          height: Go.r(64),
          padding: const EdgeInsets.symmetric(horizontal: Go.sp2),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: pal.card, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsBodySm, color: pal.ink)),
        ),
      );
}

/// 朗读音色弹层：Edge 神经音色（点选即保存 + 试听，需联网，失败自动回落实机朗读）+ 语速档位。
/// 与词卡/翻译弹层一致走墨卡：两种阅读主题下都保持高对比。
class ReadingVoiceSheet extends ConsumerWidget {
  const ReadingVoiceSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(appConfigProvider);
    final g = GoPalette.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.7),
      decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                Expanded(child: Text('朗读音色', style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: g.onSurface))),
                GestureDetector(onTap: () => Navigator.pop(context), child: Text('×', style: TextStyle(fontSize: 24, color: g.onSurface3))),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: g.outline),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(Go.sp5, Go.sp4, Go.sp5, mq.padding.bottom + Go.sp5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final v in kEdgeVoices) _voiceRow(ref, g, v[0], v[1], cfg.ttsVoice == v[0]),
                  const SizedBox(height: Go.sp5),
                  Text('语速', style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: g.onSurface3, letterSpacing: 0.4)),
                  const SizedBox(height: Go.sp3),
                  // Wrap 而非 Row：系统字号放大/窄屏时档位按钮换行，不横向溢出。
                  Wrap(
                    spacing: Go.sp2,
                    runSpacing: Go.sp2,
                    children: [for (final s in kReadingTtsSpeeds) _speedChip(ref, g, s, cfg.ttsSpeed == s)],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceRow(WidgetRef ref, GoPalette g, String id, String label, bool on) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          await ref.read(appConfigProvider).setTts(voice: id);
          // 选中即试听固定一句，让用户马上听到音色差别（preview 内部会先 stop）。
          try {
            await ref.read(ttsProvider).preview(id);
          } catch (_) {}
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: Go.sp2),
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp4),
          decoration: BoxDecoration(
            color: on ? g.primary.withValues(alpha: 0.14) : g.surface2,
            borderRadius: BorderRadius.circular(Go.rMd),
            border: Border.all(color: on ? g.primary : g.outline, width: on ? 1 : 0.5),
          ),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: on ? FontWeight.w600 : null, color: on ? g.onSurface : g.onSurface2))),
            if (on) ...[
              const SizedBox(width: Go.sp3),
              Icon(Icons.check, size: 16, color: g.primary),
            ],
          ]),
        ),
      );

  Widget _speedChip(WidgetRef ref, GoPalette g, double v, bool on) => GestureDetector(
        onTap: () => ref.read(appConfigProvider).setTts(speed: v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
          decoration: BoxDecoration(
            color: on ? g.primary : g.surface2,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: Border.all(color: on ? g.primary : g.outline, width: 0.5),
          ),
          child: Text(v.toStringAsFixed(1), style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: on ? g.onPrimary : g.onSurface2)),
        ),
      );
}
