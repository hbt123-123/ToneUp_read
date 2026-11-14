import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:toneup_read/features/reading/controllers/reading_controller.dart';
import 'package:toneup_read/features/reading/models/reading_state.dart';
import 'package:toneup_read/features/reading/widgets/reading_paragraph.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 页头：来源 + 可点词标题 + 日期/阅读时长/AI 精选角标。
class ReadingCover extends StatelessWidget {
  final ReadingController controller;
  final GoReaderPalette pal;

  /// 正文/标题字体（阅读设置的 kReaderFonts id，空串 = 系统默认）。
  final String fontFamily;
  final void Function(int ti, bool isLong, Rect? rect) onTitleToken;

  const ReadingCover({
    super.key,
    required this.controller,
    required this.pal,
    this.fontFamily = '',
    required this.onTitleToken,
  });

  @override
  Widget build(BuildContext context) {
    final st = controller.state;
    if (st.title.isEmpty && st.sourceHost.isEmpty) return const SizedBox.shrink();
    final toks = controller.tokenize(st.title);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp6, Go.sp6, Go.sp5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (st.sourceHost.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Go.sp4),
              child: Text(st.sourceHost.toUpperCase(), style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: pal.accent)),
            ),
          if (toks.isNotEmpty)
            _TitleText(
              toks: toks,
              color: pal.ink,
              fontFamily: fontFamily,
              onTok: onTitleToken,
            ),
          const SizedBox(height: Go.sp3),
          Wrap(
            spacing: Go.sp2,
            runSpacing: Go.sp2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(st.dateText, style: TextStyle(fontSize: Go.fsMeta, color: pal.meta)),
              if (st.readMins > 0)
                Text('· ${st.readMins} 分钟阅读', style: TextStyle(fontSize: Go.fsMeta, color: pal.meta)),
              if (st.status == 'gone')
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: pal.danger.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(Go.rFull)),
                  child: Text('源已下线，显示本地缓存', style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: pal.danger)),
                ),
              if (st.useCurated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: pal.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(Go.rFull)),
                  child: Text('AI 精选版', style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: pal.accent)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 正文：封面 + 段落/图片 + 尾巴。滚动由 controller.scrollController 驱动，
/// 段落 key 挂在 controller 上供朗读跟读与定位复用。
class ReadingContent extends StatelessWidget {
  final ReadingController controller;
  final GoReaderPalette pal;
  final double fontSize;
  final double lineHeight;

  /// 正文字体（阅读设置 id，空串 = 系统默认）与段间距（dp）。
  /// 即时生效：appConfig notify → 本 widget 重建，不重载文章、不动滚动位置。
  final String fontFamily;
  final double paraSpacing;

  /// 点中某个 token（pi = -1 表示标题）；[rect] 为词的屏幕包围盒（见 ReadingParagraph.onTok）。
  final void Function(int pi, int ti, bool isLong, Rect? rect) onToken;

  /// 点在正文空白/标点上（非长按）：阅读页切换沉浸模式。
  final VoidCallback onEmptyTap;

  const ReadingContent({
    super.key,
    required this.controller,
    required this.pal,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.paraSpacing,
    required this.onToken,
    required this.onEmptyTap,
  });

  @override
  Widget build(BuildContext context) {
    final st = controller.state;
    final blocks = st.activeBlocks;
    controller.syncTokens();
    var paraIndex = -1;
    final widgets = <Widget>[];
    for (var bi = 0; bi < blocks.length; bi++) {
      final b = blocks[bi];
      if (b.type == 'p') {
        paraIndex++;
        widgets.add(_paragraph(b.text ?? '', paraIndex, pal));
      } else if (b.type == 'img' && !controller.imageFailed(bi)) {
        widgets.add(_imageBlock(b, bi, pal));
      }
    }
    return SingleChildScrollView(
      controller: controller.scrollController,
      // 末行不被手势区挡住：底部留 SafeArea + 一段余量。
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + Go.sp12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReadingCover(
            controller: controller,
            pal: pal,
            fontFamily: fontFamily,
            onTitleToken: (ti, isLong, rect) => onToken(-1, ti, isLong, rect),
          ),
          // 标题块与正文之间用一条短分隔线收住视线（纸色/夜读都适用）。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(width: Go.sp12, height: 2, decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(Go.rFull))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp8, Go.sp6, 0),
            child: DefaultTextStyle(
              style: TextStyle(
                fontSize: fontSize,
                height: lineHeight,
                // 空串 = 系统默认，不设 fontFamily。
                fontFamily: fontFamily.isEmpty ? null : fontFamily,
                color: pal.ink,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Go.sp12),
            child: Text('— 全文完 —', textAlign: TextAlign.center, style: TextStyle(color: pal.meta, fontSize: Go.fsMeta, letterSpacing: 1)),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(String text, int pi, GoReaderPalette pal) {
    final toks = controller.tokensAt(pi);
    final starts = controller.startsAt(pi);
    return Container(
      key: controller.paraKey(pi),
      // 段距由阅读设置驱动（默认 18dp，长文阅读的段落呼吸感）。
      margin: EdgeInsets.only(bottom: paraSpacing),
      child: GestureDetector(
        onLongPress: () => controller.onParaLongPress(pi),
        child: ReadingParagraph(
          pi: pi,
          toks: toks,
          starts: starts,
          sel: controller.sel,
          selVer: controller.selVer,
          flashTok: controller.flashPara == pi ? controller.flashTok : -1,
          selBg: pal.sel,
          flashColor: pal.accent,
          segs: controller.segs,
          segVer: controller.ttsSegVer,
          segBg: pal.accent.withValues(alpha: 0.14),
          onTok: (ti, isLong, rect) => onToken(pi, ti, isLong, rect),
          onEmptyTap: onEmptyTap,
          onEmptyLongPress: () => controller.onParaLongPress(pi),
        ),
      ),
    );
  }

  Widget _imageBlock(ArticleBlock b, int bi, GoReaderPalette pal) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Go.sp5),
      decoration: BoxDecoration(color: pal.card, borderRadius: BorderRadius.circular(Go.rMd)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Image.network(
            controller.imageSrc(b, bi),
            fit: BoxFit.fitWidth,
            errorBuilder: (_, _, _) {
              WidgetsBinding.instance.addPostFrameCallback((_) => controller.onImageError(bi));
              return const SizedBox(height: 60);
            },
          ),
          if (b.alt != null && b.alt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Go.sp3, Go.sp2, Go.sp3, Go.sp3),
              child: Text(b.alt!, style: TextStyle(fontSize: Go.fsMeta, color: pal.meta, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

/// 标题：整条标题排成一个 `Text.rich`。
/// 以前是 `Wrap` + 每个 token 一个 `Text`——那样超长单词没有行内换行机会，只能溢出/裁切；
/// 合成一段文本后交给引擎断行，长词会正常折行。
/// 点击/长按仍按 token 命中：共用一个 `TapGestureRecognizer`，拿到字符偏移后二分定位 token（同 ReadingParagraph）。
class _TitleText extends StatefulWidget {
  final List<ReadingToken> toks;

  /// 点中某个词；[rect] 为该词的屏幕包围盒（同 ReadingParagraph.onTok）。
  final void Function(int ti, bool isLong, Rect? rect) onTok;

  /// 标题 ink（默认沿用深色 token；阅读页换肤时传入）。
  final Color color;

  /// 字体 id（阅读设置，空串 = 系统默认）。
  final String fontFamily;

  const _TitleText({required this.toks, required this.onTok, this.color = const Color(0xFFECE9F5), this.fontFamily = ''});

  @override
  State<_TitleText> createState() => _TitleTextState();
}

class _TitleTextState extends State<_TitleText> {
  final _rpKey = GlobalKey();
  late final TapGestureRecognizer _tap;
  late List<int> _starts;

  TextStyle get _style => TextStyle(
        fontFamily: Go.titleFont(widget.fontFamily),
        fontWeight: FontWeight.w700,
        fontSize: Go.fsDisplay,
        height: Go.lhTight,
        color: widget.color,
      );

  @override
  void initState() {
    super.initState();
    _tap = TapGestureRecognizer()..onTapUp = (d) => _hit(d.globalPosition, false);
    _starts = _offsets(widget.toks);
  }

  @override
  void didUpdateWidget(covariant _TitleText old) {
    super.didUpdateWidget(old);
    if (!identical(old.toks, widget.toks)) _starts = _offsets(widget.toks);
  }

  static List<int> _offsets(List<ReadingToken> toks) {
    final out = <int>[];
    var acc = 0;
    for (final t in toks) {
      out.add(acc);
      acc += t.text.length;
    }
    return out;
  }

  void _hit(Offset global, bool isLong) {
    final ro = _rpKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final pos = ro.getPositionForOffset(ro.globalToLocal(global));
    var lo = 0;
    var hi = _starts.length - 1;
    var ti = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_starts[mid] <= pos.offset) {
        ti = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (ti < 0 || ti >= widget.toks.length || !widget.toks[ti].word) return;
    widget.onTok(ti, isLong, _wordRect(ro, global, ti));
  }

  /// 点击词的屏幕包围盒（同 ReadingParagraph._wordRect；标题无缩进，偏移从 0 起）。
  Rect? _wordRect(RenderParagraph ro, Offset global, int ti) {
    try {
      final boxes = ro.getBoxesForSelection(TextSelection(baseOffset: _starts[ti], extentOffset: _starts[ti] + widget.toks[ti].text.length));
      if (boxes.isEmpty) return null;
      final local = ro.globalToLocal(global);
      var pick = boxes.first;
      for (final b in boxes) {
        final r = b.toRect();
        if (local.dy >= r.top && local.dy <= r.bottom) {
          pick = b;
          break;
        }
      }
      final rect = pick.toRect();
      return ro.localToGlobal(rect.topLeft) & rect.size;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (d) => _hit(d.globalPosition, true),
      child: Text.rich(
        key: _rpKey,
        TextSpan(
          style: _style,
          children: [
            for (final tk in widget.toks) TextSpan(text: tk.text, recognizer: tk.word ? _tap : null),
          ],
        ),
      ),
    );
  }
}
