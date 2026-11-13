import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:toneup_read/features/reading/models/reading_state.dart';

/// 单段正文：整段共用一个点击识别器，命中后用二分查找定位词，
/// 取代「每个词一个 WidgetSpan + GestureDetector」（实测 800 词 671ms → 约 40ms）；
/// 并且只有本段的选中集合发生变化时才重建，点一个词不再重建整篇。
class ReadingParagraph extends StatefulWidget {
  final int pi;
  final List<ReadingToken> toks;
  final List<int> starts;
  final Set<int> sel;
  final ValueNotifier<int> selVer;
  final int flashTok;
  final void Function(int ti, bool isLong) onTok;
  final VoidCallback onEmptyLongPress;

  /// 选中高亮底色 / 朗读定位闪色（默认沿用深色 token，阅读页换肤时传入）。
  final Color selBg;
  final Color flashColor;

  /// 跟读高亮：句表（身份在整次朗读中保持稳定）+ 当前句下标通知 + 高亮底色。
  /// 本段只在「当前句属于自己」的 token 区间变化时才重建，整页不重建。
  final List<TtsSegment> segs;
  final ValueNotifier<int> segVer;
  final Color segBg;

  const ReadingParagraph({
    super.key,
    required this.pi,
    required this.toks,
    required this.starts,
    required this.sel,
    required this.selVer,
    required this.flashTok,
    required this.onTok,
    required this.onEmptyLongPress,
    this.selBg = const Color(0x4DE072B0),
    this.flashColor = const Color(0xFF8B5CF6),
    this.segs = const [],
    required this.segVer,
    this.segBg = const Color(0x248B5CF6),
  });

  @override
  State<ReadingParagraph> createState() => _ReadingParagraphState();
}

class _ReadingParagraphState extends State<ReadingParagraph> {
  final _rpKey = GlobalKey();
  Set<int> _mine = const {};
  late final TapGestureRecognizer _tap;

  /// 当前句在本段的 token 区间（-1/-1 = 不高亮）。
  int _segFrom = -1;
  int _segTo = -1;
  static const _indent = TextSpan(text: '\u2003\u2003');

  @override
  void initState() {
    super.initState();
    // 用 onTapUp 而非 onTapDown：按下即触发会抢走长按手势，导致长按无法选中正文。
    _tap = TapGestureRecognizer()..onTapUp = (d) => _hit(d.globalPosition, false);
    widget.selVer.addListener(_onSelChanged);
    widget.segVer.addListener(_onSegChanged);
    _mine = _slice();
    _syncSeg();
  }

  @override
  void didUpdateWidget(covariant ReadingParagraph old) {
    super.didUpdateWidget(old);
    if (old.selVer != widget.selVer) {
      old.selVer.removeListener(_onSelChanged);
      widget.selVer.addListener(_onSelChanged);
    }
    if (old.segVer != widget.segVer) {
      old.segVer.removeListener(_onSegChanged);
      widget.segVer.addListener(_onSegChanged);
    }
    _mine = _slice();
    _syncSeg();
  }

  void _onSelChanged() {
    final next = _slice();
    if (setEquals(next, _mine)) return;
    setState(() => _mine = next);
  }

  /// 当前朗读句变化：只有本段的区间真的变了才 setState（其它段安静跳过）。
  void _onSegChanged() {
    final oldFrom = _segFrom, oldTo = _segTo;
    _syncSeg();
    if (_segFrom == oldFrom && _segTo == oldTo) return;
    if (!mounted) return;
    setState(() {});
  }

  void _syncSeg() {
    final idx = widget.segVer.value;
    var from = -1, to = -1;
    if (idx >= 0 && idx < widget.segs.length) {
      final s = widget.segs[idx];
      if (s.pi == widget.pi) {
        from = s.tiStart;
        to = s.tiEnd;
      }
    }
    _segFrom = from;
    _segTo = to;
  }

  Set<int> _slice() {
    final out = <int>{};
    for (final k in widget.sel) {
      if ((k >> 20) == widget.pi) out.add(k & 0xFFFFF);
    }
    return out;
  }

  void _hit(Offset global, bool isLong) {
    final ro = _rpKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final pos = ro.getPositionForOffset(ro.globalToLocal(global));
    final ti = _tokenAt(pos.offset);
    final onWord = ti >= 0 && ti < widget.toks.length && widget.toks[ti].word;
    if (!onWord) {
      // 长按落在标点/空白上：保持旧行为，交给整段选择
      if (isLong) widget.onEmptyLongPress();
      return;
    }
    widget.onTok(ti, isLong);
  }

  /// 字符偏移 → token 下标：O(log n) 二分，取代按 token 逐个命中测试。
  int _tokenAt(int offset) {
    final starts = widget.starts;
    var lo = 0;
    var hi = starts.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  @override
  void dispose() {
    widget.selVer.removeListener(_onSelChanged);
    widget.segVer.removeListener(_onSegChanged);
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return GestureDetector(
      onLongPressStart: (d) => _hit(d.globalPosition, true),
      child: Text.rich(
        key: _rpKey,
        TextSpan(
          style: base,
          children: [
            _indent,
            for (var ti = 0; ti < widget.toks.length; ti++) _span(widget.toks[ti], ti),
          ],
        ),
      ),
    );
  }

  InlineSpan _span(ReadingToken tk, int ti) {
    final selected = _mine.contains(ti);
    final flash = widget.flashTok == ti;
    final speaking = ti >= _segFrom && ti <= _segTo;
    if (selected || flash || speaking) {
      final style = TextStyle(
        // 选中优先于跟读：选区加粗的语义不能被跟读底色盖掉。
        backgroundColor: selected ? widget.selBg : widget.segBg,
        fontWeight: selected ? FontWeight.w600 : null,
        color: flash ? widget.flashColor : null,
      );
      if (!tk.word) return TextSpan(text: tk.text, style: style);
      return TextSpan(text: tk.text, style: style, recognizer: _tap);
    }
    if (!tk.word) return TextSpan(text: tk.text);
    return TextSpan(text: tk.text, recognizer: _tap);
  }
}
