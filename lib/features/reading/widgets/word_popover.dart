import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/reading/widgets/word_card_data.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 点词「就地浮窗」：锚定在被点词的旁边（上方优先、下方兜底），几乎不遮正文。
/// 只放核心信息——词、音标、发音、前两条释义、收录；「详情」展开完整词卡
/// [WordCardSheet]（词形/考试标签/词频/建议词/中英切换都在那边）。
///
/// 配色用 [GoReaderPalette] 与阅读页同肤（区别于完整词卡弹层的 App 明暗主题）。
class WordPopover extends ConsumerStatefulWidget {
  final String word;
  final GoReaderPalette pal;

  /// 收录生词时的上下文（与词卡弹层一致）。
  final String sentence;
  final String articleGuid;
  final String articleTitle;
  final String sourceLabel;
  final int paraIndex;
  final int tokIndex;

  /// 内容区高度上限：由锚定计算方给出（上方/下方的可用空间），超出内部滚动。
  final double maxHeight;
  final VoidCallback onClose;
  final VoidCallback onDetail;
  final Future<void> Function(String word) onSpeak;

  const WordPopover({
    super.key,
    required this.word,
    required this.pal,
    required this.sentence,
    required this.articleGuid,
    required this.articleTitle,
    required this.sourceLabel,
    required this.paraIndex,
    required this.tokIndex,
    required this.maxHeight,
    required this.onClose,
    required this.onDetail,
    required this.onSpeak,
  });

  @override
  ConsumerState<WordPopover> createState() => _WordPopoverState();
}

class _WordPopoverState extends ConsumerState<WordPopover> {
  bool _loading = true;
  String _error = '';
  Map<String, dynamic>? _card;
  String _text = '';
  bool _added = false;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    setState(() {
      _loading = true;
      _error = '';
      _card = null;
      _text = '';
    });
    try {
      final raw = await ref.read(wordProvider).lookup(widget.word, mode: 'en2zh');
      if (!mounted) return;
      if (raw.trim().isEmpty) {
        // 服务端失败冷却期内返回空串。
        setState(() => _error = '未获取到释义，请重试');
        return;
      }
      final p = parseLookup(raw);
      if (p.card != null) {
        setState(() => _card = p.card);
      } else if (p.text.isEmpty) {
        setState(() => _error = '未获取到释义，请重试');
      } else {
        setState(() => _text = p.text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '查询失败：${errText(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addToVocab() async {
    if (_added) return;
    try {
      await ref.read(vocabProvider).recordOccurrence(widget.word, widget.sentence, widget.articleGuid, widget.articleTitle, widget.sourceLabel, widget.paraIndex, widget.tokIndex);
      ref.read(vocabRevisionProvider.notifier).bump();
      if (!mounted) return;
      setState(() => _added = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已收录到生词库'), duration: Duration(seconds: 2)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收录失败：${errText(e)}'), duration: const Duration(seconds: 2)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.pal;
    return Container(
      width: _popWidth(context),
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(Go.rLg),
        border: Border.all(color: pal.divider, width: 0.8),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: pal.isNight ? 0.5 : 0.18), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp4, Go.sp5, Go.sp3),
      // 浮窗文字同样不许套固定高度（textScaler 铁律）；高度由内容 + maxHeight 收口。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(pal),
          const SizedBox(height: Go.sp3),
          Flexible(child: _body(pal)),
          const SizedBox(height: Go.sp2),
          _footer(pal),
        ],
      ),
    );
  }

  /// 窗宽：内容可读性优先，窄屏收到「屏宽 - 两边距」。
  double _popWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width - Go.sp8 * 2;
    return w.clamp(200.0, 320.0);
  }

  Widget _header(GoReaderPalette pal) {
    final phonetic = '${_card?['phonetic'] ?? ''}'.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Text(
            widget.word,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: Go.fsH1, fontWeight: FontWeight.w600, height: Go.lhSnug, color: pal.ink),
          ),
        ),
        if (phonetic.isNotEmpty) ...[
          const SizedBox(width: Go.sp2),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('/$phonetic/', style: TextStyle(fontSize: Go.fsMeta, color: pal.secondary)),
          ),
        ],
        const SizedBox(width: Go.sp2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSpeak(widget.word),
          child: Padding(
            padding: const EdgeInsets.all(Go.sp1),
            child: Icon(Icons.volume_up_outlined, size: 18, color: pal.accent),
          ),
        ),
        const SizedBox(width: Go.sp1),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onClose,
          child: Padding(
            padding: const EdgeInsets.all(Go.sp1),
            child: Icon(Icons.close, size: 18, color: pal.meta),
          ),
        ),
      ],
    );
  }

  Widget _body(GoReaderPalette pal) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Go.sp4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const PolySpinner(size: 16),
          const SizedBox(width: Go.sp3),
          Text('查询中…', style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary)),
        ]),
      );
    }
    if (_error.isNotEmpty) {
      return Text(_error, style: TextStyle(fontSize: Go.fsBodySm, color: pal.danger, height: Go.lhSnug));
    }
    final card = _card;
    if (card == null) {
      // kind=text / 旧缓存裸文本：译文直接展示，详细内容进完整词卡。
      return Text(_text, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: pal.ink));
    }
    if (card['found'] == false) {
      return Text('词典未收录该词，试试完整词卡里的相近词。', style: TextStyle(fontSize: Go.fsBodySm, height: Go.lhSnug, color: pal.secondary));
    }
    final senses = (card['senses'] as List? ?? const []).whereType<Map>().toList();
    final zh = '${card['zh'] ?? ''}'.trim();
    final lines = <Widget>[];
    if (senses.isNotEmpty) {
      for (final s in senses.take(2)) {
        final pos = '${s['pos'] ?? ''}'.trim();
        final def = '${s['definition'] ?? ''}'.trim();
        if (def.isEmpty) continue;
        lines.add(Padding(
          padding: const EdgeInsets.only(bottom: Go.sp1),
          child: Text.rich(
            TextSpan(children: [
              if (pos.isNotEmpty) TextSpan(text: '$pos. ', style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: pal.accent)),
              TextSpan(text: def, style: TextStyle(fontSize: Go.fsBody, height: Go.lhNormal, color: pal.ink)),
            ]),
          ),
        ));
      }
    } else if (zh.isNotEmpty) {
      lines.add(Text(zh, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: pal.ink)));
    }
    if (lines.isEmpty) {
      return Text('未获取到释义', style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary));
    }
    // 释义区自身可滚动兜底：系统字号放大 + 长释义时也不顶破 maxHeight。
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: lines));
  }

  Widget _footer(GoReaderPalette pal) {
    // Wrap 而非 Row：系统字号放大时按钮换行，不横向溢出（textScaler 铁律）。
    return Wrap(
      spacing: Go.sp3,
      runSpacing: Go.sp2,
      children: [
        _btn(pal, '详情', widget.onDetail, filled: false),
        if (_error.isEmpty) _btn(pal, _added ? '已收录' : '加入生词库', _added ? () {} : _addToVocab, filled: true, dim: _added),
      ],
    );
  }

  Widget _btn(GoReaderPalette pal, String label, VoidCallback onTap, {required bool filled, bool dim = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
          decoration: BoxDecoration(
            color: filled ? (dim ? pal.card : pal.accent) : Colors.transparent,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: filled ? null : Border.all(color: pal.accent, width: 1),
          ),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: filled ? (dim ? pal.secondary : Colors.white) : pal.accent)),
        ),
      );
}
