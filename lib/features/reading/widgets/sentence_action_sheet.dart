import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 划词句子面板：页签「翻译」（网关整句/整段翻译）与「AI 分析」（语法/语块拆解，
/// 走 VocabService.analyzeSentence，结果缓存进 vocab_sentence.analysis——
/// 已分析过的句子秒出，且分析即收藏，收藏页可回跳原文）。
/// 全部在阅读页内的底部弹层完成，不跳页。
class SentenceActionSheet extends ConsumerStatefulWidget {
  final String text;
  final VoidCallback onClose;

  /// 收藏/分析时的上下文锚点（标题等场景可能没有，传空串则只展示不收藏）。
  final String articleGuid;
  final String articleTitle;
  final String sourceLabel;
  final int paraIndex;
  final int tokIndex;

  const SentenceActionSheet({
    super.key,
    required this.text,
    required this.onClose,
    this.articleGuid = '',
    this.articleTitle = '',
    this.sourceLabel = '',
    this.paraIndex = -1,
    this.tokIndex = -1,
  });

  @override
  ConsumerState<SentenceActionSheet> createState() => _SentenceActionSheetState();
}

class _SentenceActionSheetState extends ConsumerState<SentenceActionSheet> {
  static const _tabTranslate = 0;
  static const _tabAnalyze = 1;

  int _tab = _tabTranslate;

  // —— 翻译 ——
  bool _translating = true;
  String _transError = '';
  String _out = '';

  // —— AI 分析 ——
  bool _analyzing = false;
  String _analyzeError = '';
  Map<String, dynamic>? _analysis;
  bool _analyzeStarted = false;

  @override
  void initState() {
    super.initState();
    _runTranslate();
  }

  Future<void> _runTranslate() async {
    setState(() {
      _translating = true;
      _transError = '';
      _out = '';
    });
    try {
      final r = await ref.read(translateProvider).translate(widget.text);
      if (!mounted) return;
      if (r.trim().isEmpty) {
        setState(() => _transError = '翻译结果为空，请重试');
      } else {
        setState(() => _out = r.trim());
      }
    } catch (e) {
      if (mounted) setState(() => _transError = errText(e));
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// AI 分析：先查缓存（vocab_sentence.analysis），没有才打网关。
  /// 分析即收藏：先带上下文落 vocab_sentence，收藏页「回到原文」才有锚点元数据。
  Future<void> _runAnalyze() async {
    if (_analyzing) return;
    setState(() {
      _analyzing = true;
      _analyzeError = '';
    });
    try {
      final cached = await ref.read(vocabProvider).getSentenceAnalysis(widget.text);
      if (!mounted) return;
      if (cached != null) {
        setState(() => _analysis = cached);
        return;
      }
      if (widget.articleGuid.isNotEmpty) {
        await ref.read(vocabProvider).saveSentence(widget.text, widget.articleGuid, widget.articleTitle, widget.sourceLabel, widget.paraIndex, widget.tokIndex);
        ref.read(vocabRevisionProvider.notifier).bump();
      }
      final data = await ref.read(vocabProvider).analyzeSentence(widget.text);
      if (!mounted) return;
      setState(() => _analysis = data);
    } catch (e) {
      if (mounted) setState(() => _analyzeError = errText(e));
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  void _switchTab(int t) {
    setState(() => _tab = t);
    if (t == _tabAnalyze && !_analyzeStarted && _analysis == null) {
      _analyzeStarted = true;
      _runAnalyze();
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      height: MediaQuery.of(context).size.height * 0.45,
      decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                _tabBtn(g, '翻译', _tab == _tabTranslate, () => _switchTab(_tabTranslate)),
                const SizedBox(width: Go.sp2),
                _tabBtn(g, 'AI 分析', _tab == _tabAnalyze, () => _switchTab(_tabAnalyze)),
                const Spacer(),
                if (_canCopy) _sheetBtn(g, '复制', _copy),
                const SizedBox(width: Go.sp3),
                GestureDetector(onTap: widget.onClose, child: Text('×', style: TextStyle(fontSize: 24, color: g.onSurface3))),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: g.outline),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Go.sp6),
              child: _tab == _tabTranslate ? _translateBody(g) : _analyzeBody(g),
            ),
          ),
        ],
      ),
    );
  }

  bool get _canCopy => (_tab == _tabTranslate && _out.isNotEmpty) || (_tab == _tabAnalyze && _analysis != null);

  Future<void> _copy() async {
    final text = _tab == _tabTranslate
        ? _out
        : (() {
            final a = _analysis;
            if (a == null) return '';
            final buf = StringBuffer('${a['translation'] ?? ''}');
            for (final c in (a['chunks'] as List? ?? const [])) {
              buf.write('\n${c['text']} — ${c['note']}');
            }
            return buf.toString();
          })();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
  }

  Widget _translateBody(GoPalette g) {
    if (_translating) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('翻译中…', style: TextStyle(color: g.onSurface3))]));
    }
    if (_transError.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_transError, style: TextStyle(color: g.danger, fontSize: Go.fsBodySm)),
        const SizedBox(height: Go.sp3),
        GestureDetector(onTap: _runTranslate, child: Text('重试', style: TextStyle(color: g.primary, fontWeight: FontWeight.w600))),
      ]);
    }
    return Text(_out, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: g.onSurface));
  }

  Widget _analyzeBody(GoPalette g) {
    if (_analyzing) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('AI 分析中…', style: TextStyle(color: g.onSurface3))]));
    }
    if (_analyzeError.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_analyzeError, style: TextStyle(color: g.danger, fontSize: Go.fsBodySm)),
        const SizedBox(height: Go.sp3),
        GestureDetector(onTap: _runAnalyze, child: Text('重试', style: TextStyle(color: g.primary, fontWeight: FontWeight.w600))),
      ]);
    }
    final a = _analysis;
    if (a == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: _analysisView(g, a));
  }

  /// 分析结果：整句翻译 + 语块 + 语法点 + 重点词（与收藏页句子卡同一 shape）。
  List<Widget> _analysisView(GoPalette g, Map analysis) {
    final out = <Widget>[];
    final translation = '${analysis['translation'] ?? ''}'.trim();
    if (translation.isNotEmpty) {
      out.add(Text(translation, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: g.onSurface)));
    }
    final chunks = (analysis['chunks'] as List? ?? const []).whereType<Map>().toList();
    if (chunks.isNotEmpty) {
      out.add(_section(g, '语块', [
        for (final c in chunks) _row(g, '${c['text']}', '${c['type']} · ${c['note']}'),
      ]));
    }
    final grammar = (analysis['grammar'] as List? ?? const []).whereType<Map>().toList();
    if (grammar.isNotEmpty) {
      out.add(_section(g, '语法', [
        for (final item in grammar) _row(g, '${item['point']}', '${item['explain']}'),
      ]));
    }
    final keywords = (analysis['keywords'] as List? ?? const []).whereType<Map>().toList();
    if (keywords.isNotEmpty) {
      out.add(_section(g, '重点词', [
        for (final k in keywords) _row(g, '${k['word']} ${k['pos'] ?? ''}', '${k['zh']}'),
      ]));
    }
    if (out.isEmpty) out.add(Text('未获取到分析结果', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface3)));
    return out;
  }

  Widget _section(GoPalette g, String title, List<Widget> rows) => Padding(
        padding: const EdgeInsets.only(top: Go.sp4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: Go.fsMeta, color: g.primary, fontWeight: FontWeight.w600)),
            ...rows,
          ],
        ),
      );

  Widget _row(GoPalette g, String k, String v) => Container(
        padding: const EdgeInsets.symmetric(vertical: Go.sp2),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: g.outline, width: 0.5))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: TextStyle(fontSize: Go.fsBody, color: g.onSurface)),
            Text(v, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
          ],
        ),
      );

  Widget _tabBtn(GoPalette g, String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
          decoration: BoxDecoration(
            color: on ? g.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: Border.all(color: on ? g.primary : g.outline, width: 0.5),
          ),
          child: Text(label, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: on ? g.onPrimary : g.onSurface3)),
        ),
      );

  Widget _sheetBtn(GoPalette g, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
          decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface)),
        ),
      );
}
