import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/screens/article_screen.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 句子收藏页（tab 2）：从 vocab_screen 拆出的句子视图，
/// 新增网关翻译 / 朗读 / 复制，保留「回到原文」与「LLM 拆解」。
class SentenceScreen extends ConsumerStatefulWidget {
  const SentenceScreen({super.key});
  @override
  ConsumerState<SentenceScreen> createState() => _SentenceScreenState();
}

class _SentenceScreenState extends ConsumerState<SentenceScreen> {
  List<Map<String, dynamic>> _sentences = [];
  Timer? _reloadTimer;
  int _seenRev = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    super.dispose();
  }

  /// 句子在别处被改动时刷新（防抖：连续点词只重载一次）。
  void _onVocabChanged() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    try {
      final rawSent = await ref.read(vocabProvider).getSentences();
      _sentences = rawSent.map((s) {
        dynamic a;
        try {
          if (s['analysis'] != null) a = jsonDecode(s['analysis'] as String);
        } catch (_) {}
        return {...s, '_analysis': a, '_analyzing': false, '_translating': false, '_trans': null, '_transErr': null};
      }).toList();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('句子加载失败: $e')));
    }
  }

  Future<void> _onTranslate(Map<String, dynamic> s) async {
    final text = '${s['sentence'] ?? ''}';
    if (text.trim().isEmpty) return;
    setState(() {
      s['_translating'] = true;
      s['_trans'] = null;
      s['_transErr'] = null;
    });
    try {
      final out = await ref.read(translateProvider).translate(text, from: 'en', to: 'zh');
      if (!mounted) return;
      setState(() {
        s['_translating'] = false;
        s['_trans'] = out;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        s['_translating'] = false;
        s['_transErr'] = errText(e);
      });
    }
  }

  void _onSpeak(Map<String, dynamic> s) {
    final text = '${s['sentence'] ?? ''}';
    if (text.trim().isEmpty) return;
    ref.read(ttsProvider).speak(text);
  }

  Future<void> _onCopySentence(Map<String, dynamic> s) async {
    final text = '${s['sentence'] ?? ''}';
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制句子')));
  }

  void _goArticle(Map<String, dynamic> s) {
    final guid = s['articleGuid'] as String?;
    if (guid == null || guid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArticleScreen(guid: guid, focusPara: (s['paraIndex'] as int?) ?? -1, focusTok: (s['tokIndex'] as int?) ?? -1),
      ),
    );
  }

  Future<void> _onAnalyze(Map<String, dynamic> s) async {
    if (s['sentence'] == null) return;
    setState(() => s['_analyzing'] = true);
    try {
      final data = await ref.read(vocabProvider).analyzeSentence(s['sentence'] as String);
      if (!mounted) return;
      setState(() => s['_analysis'] = data);
    } catch (e) {
      if (!mounted) return;
      final msg = errText(e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg.length > 60 ? msg.substring(0, 60) : msg)));
    } finally {
      if (mounted) setState(() => s['_analyzing'] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onThisTab = ref.watch(tabIndexProvider) == 2;
    // 只有本页可见时才响应词汇变更：阅读中每点一个词都会 bump，
    // 隐藏的 Tab 若跟着全量重载会拖慢阅读。
    if (onThisTab) {
      ref.listen(vocabRevisionProvider, (_, _) {
        _seenRev = ref.read(vocabRevisionProvider);
        _onVocabChanged();
      });
      // 切回本页时若期间有变更，补一次刷新，避免看到旧数据。
      final rev = ref.read(vocabRevisionProvider);
      if (rev != _seenRev) {
        _seenRev = rev;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onVocabChanged();
        });
      }
    }
    final empty = _sentences.isEmpty;
    return GoPage(
      topPad: false,
      globe: true,
      globeActive: onThisTab && empty,
      child: Column(
        children: [
          const GoAppBar(title: '句子收藏', style: GoAppBarStyle.floating),
          Expanded(child: _sentenceScroll()),
        ],
      ),
    );
  }

  /// 收藏句子最多 200 条（getSentences 内 LIMIT），直接单列铺开即可。
  Widget _sentenceScroll() {
    if (_sentences.isEmpty) {
      return const GoEmpty(icon: 'reading', title: '还没有收藏的句子', desc: '在正文里点词，原句会自动沉淀到这里');
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp2, Go.sp6, Go.sp2),
            child: Text('${_sentences.length} 个收藏句子', style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp2, Go.sp6, Go.sp8),
            child: Column(children: [for (final s in _sentences) _sentenceCard(s)]),
          ),
          const SizedBox(height: Go.sp16),
        ],
      ),
    );
  }

  Widget _sentenceCard(Map<String, dynamic> s) {
    final analysis = s['_analysis'];
    final translating = s['_translating'] == true;
    final trans = s['_trans'] as String?;
    final transErr = s['_transErr'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: Go.sp4),
      padding: const EdgeInsets.all(Go.sp5),
      decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rLg), border: Border.all(color: Go.outline, width: 0.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('“${s['sentence']}”', style: const TextStyle(fontSize: Go.fsBody, height: 1.6, color: Go.onSurface)),
          Padding(
            padding: const EdgeInsets.only(top: Go.sp2),
            child: Text('${s['sourceLabel'] ?? '来源'} · ${s['articleTitle'] ?? ''}', style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Go.sp4),
            child: Wrap(
              spacing: Go.sp3,
              runSpacing: Go.sp2,
              children: [
                _miniBtn(trans != null ? '重新翻译' : '翻译', () => _onTranslate(s)),
                _miniBtn('朗读', () => _onSpeak(s)),
                _miniBtn('复制', () => _onCopySentence(s)),
                _miniBtn('回到原文', () => _goArticle(s)),
                _miniBtn(s['_analyzing'] == true ? '拆解中…' : (analysis != null ? '重新拆解' : 'LLM 拆解'), () => _onAnalyze(s), ai: true),
              ],
            ),
          ),
          if (translating)
            const Padding(
              padding: EdgeInsets.only(top: Go.sp3),
              child: Row(
                children: [
                  PolySpinner(size: 20),
                  SizedBox(width: Go.sp3),
                  Text('翻译中…', style: TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
                ],
              ),
            ),
          if (trans != null && !translating)
            Container(
              margin: const EdgeInsets.only(top: Go.sp3),
              padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
              decoration: BoxDecoration(color: Go.primary95, borderRadius: BorderRadius.circular(Go.rMd)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(trans, style: const TextStyle(fontSize: Go.fsBody, height: 1.6, color: Go.onSurface)),
                  Padding(
                    padding: const EdgeInsets.only(top: Go.sp2),
                    child: _miniBtn('复制译文', () async {
                      await Clipboard.setData(ClipboardData(text: trans));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制译文')));
                    }),
                  ),
                ],
              ),
            ),
          if (transErr != null && !translating)
            Padding(
              padding: const EdgeInsets.only(top: Go.sp3),
              child: Text(transErr, style: const TextStyle(fontSize: Go.fsMeta, color: Go.danger)),
            ),
          if (analysis is Map) _analysisView(analysis),
        ],
      ),
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap, {bool ai = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp1),
          decoration: BoxDecoration(border: Border.all(color: ai ? Go.primary : Go.outline), borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: ai ? Go.primary : Go.onSurface2)),
        ),
      );

  Widget _analysisView(Map analysis) {
    return Container(
      margin: const EdgeInsets.only(top: Go.sp4),
      padding: const EdgeInsets.only(top: Go.sp3),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Go.outline, width: 0.5, style: BorderStyle.solid))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ('${analysis['translation'] ?? ''}'.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: Go.sp3), child: Text('${analysis['translation']}', style: const TextStyle(fontSize: Go.fsBody, color: Go.onSurface))),
          if (analysis['chunks'] is List && (analysis['chunks'] as List).isNotEmpty)
            _analysisSection('语块', [
              for (final c in analysis['chunks'] as List) _analysisRow('${c['text']}', '${c['type']} · ${c['note']}'),
            ]),
          if (analysis['grammar'] is List && (analysis['grammar'] as List).isNotEmpty)
            _analysisSection('语法', [
              for (final g in analysis['grammar'] as List) _analysisRow('${g['point']}', '${g['explain']}'),
            ]),
          if (analysis['keywords'] is List && (analysis['keywords'] as List).isNotEmpty)
            _analysisSection('重点词', [
              for (final k in analysis['keywords'] as List) _analysisRow('${k['word']} ${k['pos'] ?? ''}', '${k['zh']}'),
            ]),
        ],
      ),
    );
  }

  Widget _analysisSection(String title, List<Widget> rows) => Padding(
        padding: const EdgeInsets.only(bottom: Go.sp3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: Go.fsMeta, color: Go.primary, fontWeight: FontWeight.w600)),
            ...rows,
          ],
        ),
      );

  Widget _analysisRow(String k, String v) => Container(
        padding: const EdgeInsets.symmetric(vertical: Go.sp2),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Go.outline, width: 0.5))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: const TextStyle(fontSize: Go.fsBody, color: Go.onSurface)),
            Text(v, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
          ],
        ),
      );
}
