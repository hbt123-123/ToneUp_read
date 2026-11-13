import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 收藏句子卡片：原句 + 来源 + 翻译/朗读/复制/回到原文/LLM 拆解 + 结果区。
class FavoriteSentenceCard extends StatelessWidget {
  final Map<String, dynamic> sentence;
  final VoidCallback onTranslate;
  final VoidCallback onSpeak;
  final VoidCallback onCopy;
  final VoidCallback onOpenArticle;
  final VoidCallback onAnalyze;
  final ValueChanged<String> onCopyTranslation;

  const FavoriteSentenceCard({
    super.key,
    required this.sentence,
    required this.onTranslate,
    required this.onSpeak,
    required this.onCopy,
    required this.onOpenArticle,
    required this.onAnalyze,
    required this.onCopyTranslation,
  });

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final analysis = sentence['_analysis'];
    final translating = sentence['_translating'] == true;
    final trans = sentence['_trans'] as String?;
    final transErr = sentence['_transErr'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: Go.sp4),
      padding: const EdgeInsets.all(Go.sp5),
      decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rLg), border: Border.all(color: g.outline, width: 0.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('“${sentence['sentence']}”', style: TextStyle(fontSize: Go.fsBody, height: 1.6, color: g.onSurface)),
          Padding(
            padding: const EdgeInsets.only(top: Go.sp2),
            child: Text('${sentence['sourceLabel'] ?? '来源'} · ${sentence['articleTitle'] ?? ''}',
                style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Go.sp4),
            child: Wrap(
              spacing: Go.sp3,
              runSpacing: Go.sp2,
              children: [
                _miniBtn(g, trans != null ? '重新翻译' : '翻译', onTranslate),
                _miniBtn(g, '朗读', onSpeak),
                _miniBtn(g, '复制', onCopy),
                _miniBtn(g, '回到原文', onOpenArticle),
                _miniBtn(g, sentence['_analyzing'] == true ? '拆解中…' : (analysis != null ? '重新拆解' : 'LLM 拆解'), onAnalyze, ai: true),
              ],
            ),
          ),
          if (translating)
            Padding(
              padding: const EdgeInsets.only(top: Go.sp3),
              child: Row(
                children: [
                  const PolySpinner(size: 20),
                  const SizedBox(width: Go.sp3),
                  Text('翻译中…', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
                ],
              ),
            ),
          if (trans != null && !translating)
            Container(
              margin: const EdgeInsets.only(top: Go.sp3),
              padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
              decoration: BoxDecoration(color: g.primary95, borderRadius: BorderRadius.circular(Go.rMd)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(trans, style: TextStyle(fontSize: Go.fsBody, height: 1.6, color: g.onSurface)),
                  Padding(
                    padding: const EdgeInsets.only(top: Go.sp2),
                    child: _miniBtn(g, '复制译文', () => onCopyTranslation(trans)),
                  ),
                ],
              ),
            ),
          if (transErr != null && !translating)
            Padding(
              padding: const EdgeInsets.only(top: Go.sp3),
              child: Text(transErr, style: TextStyle(fontSize: Go.fsMeta, color: g.danger)),
            ),
          if (analysis is Map) _analysisView(g, analysis),
        ],
      ),
    );
  }

  Widget _miniBtn(GoPalette g, String label, VoidCallback onTap, {bool ai = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp1),
          decoration: BoxDecoration(border: Border.all(color: ai ? g.primary : g.outline), borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: ai ? g.primary : g.onSurface2)),
        ),
      );

  Widget _analysisView(GoPalette g, Map analysis) {
    return Container(
      margin: const EdgeInsets.only(top: Go.sp4),
      padding: const EdgeInsets.only(top: Go.sp3),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: g.outline, width: 0.5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ('${analysis['translation'] ?? ''}'.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: Go.sp3), child: Text('${analysis['translation']}', style: TextStyle(fontSize: Go.fsBody, color: g.onSurface))),
          if (analysis['chunks'] is List && (analysis['chunks'] as List).isNotEmpty)
            _analysisSection(g, '语块', [
              for (final c in analysis['chunks'] as List) _analysisRow(g, '${c['text']}', '${c['type']} · ${c['note']}'),
            ]),
          if (analysis['grammar'] is List && (analysis['grammar'] as List).isNotEmpty)
            _analysisSection(g, '语法', [
              for (final item in analysis['grammar'] as List) _analysisRow(g, '${item['point']}', '${item['explain']}'),
            ]),
          if (analysis['keywords'] is List && (analysis['keywords'] as List).isNotEmpty)
            _analysisSection(g, '重点词', [
              for (final k in analysis['keywords'] as List) _analysisRow(g, '${k['word']} ${k['pos'] ?? ''}', '${k['zh']}'),
            ]),
        ],
      ),
    );
  }

  Widget _analysisSection(GoPalette g, String title, List<Widget> rows) => Padding(
        padding: const EdgeInsets.only(bottom: Go.sp3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: Go.fsMeta, color: g.primary, fontWeight: FontWeight.w600)),
            ...rows,
          ],
        ),
      );

  Widget _analysisRow(GoPalette g, String k, String v) => Container(
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
}
