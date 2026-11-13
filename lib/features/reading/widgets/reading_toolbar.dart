import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 选区操作条：朗读 / 查询 / 翻译 / 收藏 / 取消。
class ReadingSelectionBar extends StatelessWidget {
  final GoReaderPalette pal;
  final String text;
  final VoidCallback onRead;
  final VoidCallback onQuery;
  final VoidCallback onTranslate;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const ReadingSelectionBar({
    super.key,
    required this.pal,
    required this.text,
    required this.onRead,
    required this.onQuery,
    required this.onTranslate,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final preview = text.length > 24 ? '${text.substring(0, 24)}…' : text;
    return Positioned(
      left: Go.sp4,
      right: Go.sp4,
      bottom: MediaQuery.of(context).padding.bottom + Go.sp4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
        decoration: BoxDecoration(color: pal.bar, borderRadius: BorderRadius.circular(Go.rLg), border: Border.all(color: pal.divider, width: 0.5)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: pal.onBar, fontSize: Go.fsBodySm, height: Go.lhSnug)),
            const SizedBox(height: Go.sp3),
            // Wrap 而非 Row：系统字号放大时按钮换行，不会横向溢出（textScaler 回归铁律）。
            Wrap(
              spacing: Go.sp3,
              runSpacing: Go.sp2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _btn('朗读', onRead),
                _btn('查询', onQuery),
                _btn('翻译', onTranslate),
                _btn('收藏', onSave),
                GestureDetector(onTap: onCancel, child: Text('取消', style: TextStyle(color: pal.onBar.withValues(alpha: 0.7), fontSize: Go.fsBodySm))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp2),
          decoration: BoxDecoration(color: pal.accent.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(color: pal.onBar, fontSize: Go.fsBodySm)),
        ),
      );
}

/// 全文朗读状态胶囊：浮在底部，只占自身一小块（不遮内容、不拦滚动）。
/// 文案/转轮是纯装饰（IgnorePointer），只有「取消/停止」按钮可点。
/// 「正在生成语音…」= 等第一段云端音频；「朗读中 · 3/42」= 播放中（句号来自 segVer）。
class ReadingTtsPill extends StatelessWidget {
  final GoReaderPalette pal;
  final bool synthesizing;
  final ValueNotifier<int> segVer;
  final int totalSegs;
  final VoidCallback onStop;

  const ReadingTtsPill({
    super.key,
    required this.pal,
    required this.synthesizing,
    required this.segVer,
    required this.totalSegs,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: Go.sp8,
      right: Go.sp8,
      bottom: MediaQuery.of(context).padding.bottom + Go.sp6,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp3),
          decoration: BoxDecoration(
            color: pal.bar,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: Border.all(color: pal.divider, width: 0.5),
          ),
          // Wrap：系统字号放大时文字与按钮换行，不横向溢出（textScaler 铁律）。
          child: Wrap(
            spacing: Go.sp4,
            runSpacing: Go.sp2,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.center,
            children: [
              IgnorePointer(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (synthesizing) ...[
                    const PolySpinner(size: 16),
                    const SizedBox(width: Go.sp3),
                    Text('正在生成语音…', style: TextStyle(fontSize: Go.fsMeta, color: pal.onBar)),
                  ] else
                    ValueListenableBuilder<int>(
                      valueListenable: segVer,
                      builder: (_, seg, _) => Text(
                        '朗读中 · ${seg < 0 ? 1 : seg + 1}/$totalSegs',
                        style: TextStyle(fontSize: Go.fsMeta, color: pal.onBar),
                      ),
                    ),
                ]),
              ),
              GestureDetector(
                onTap: onStop,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
                  decoration: BoxDecoration(
                    color: pal.accent.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(Go.rFull),
                  ),
                  child: Text(synthesizing ? '取消' : '停止', style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: pal.onBar)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
