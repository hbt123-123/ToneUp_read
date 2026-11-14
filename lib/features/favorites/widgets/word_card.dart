import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 收藏词卡：词条 + 音标/中文释义 + 出现次数/来源数角标 + 最近原句；发音 + 删除。
class FavoriteWordCard extends StatelessWidget {
  final Map<String, dynamic> head;
  final VoidCallback onTap;
  final VoidCallback onSpeak;
  final VoidCallback onRemove;

  const FavoriteWordCard({super.key, required this.head, required this.onTap, required this.onSpeak, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final zh = head['zh'];
    final phonetic = '${head['phonetic'] ?? ''}';
    final latest = '${head['latestSentence'] ?? ''}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: Go.sp3),
        padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp4),
        decoration: BoxDecoration(color: g.surface, borderRadius: BorderRadius.circular(Go.rLg), boxShadow: g.elev1),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text('${head['head']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: g.onSurface)),
                      ),
                      const SizedBox(width: Go.sp3),
                      if ((head['occCount'] as int? ?? 0) > 1) _badge(g, '×${head['occCount']}'),
                      if ((head['sourceCount'] as int? ?? 0) > 1) ...[
                        const SizedBox(width: Go.sp2),
                        _badge(g, '${head['sourceCount']} 来源', src: true),
                      ],
                    ],
                  ),
                  if (zh != null && '$zh'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          if (phonetic.isNotEmpty) ...[
                            Text(phonetic, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
                            const SizedBox(width: Go.sp2),
                          ],
                          Expanded(
                            child: Text('$zh', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface)),
                          ),
                        ],
                      ),
                    ),
                  if (latest.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(latest.length > 70 ? latest.substring(0, 70) : latest,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
                    ),
                ],
              ),
            ),
            GoIconBtn(icon: 'tts', onTap: onSpeak, color: g.primary),
            GestureDetector(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(Go.sp2),
                child: Text('删除', style: TextStyle(fontSize: Go.fsMeta, color: g.danger)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(GoPalette g, String text, {bool src = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp2, vertical: 1),
        decoration: BoxDecoration(color: src ? g.primary95 : g.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
        child: Text(text, style: TextStyle(fontSize: Go.fsMeta, color: src ? g.primary : g.onSurface3)),
      );
}
