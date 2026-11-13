import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 词条出处弹层：列出原句与来源，点条目回到原文对应位置。
class WordOccurrenceOverlay extends StatelessWidget {
  final String head;
  final String zh;
  final List<dynamic> list;
  final VoidCallback onClose;
  final ValueChanged<Map<String, dynamic>> onOpenArticle;

  const WordOccurrenceOverlay({
    super.key,
    required this.head,
    required this.zh,
    required this.list,
    required this.onClose,
    required this.onOpenArticle,
  });

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return GestureDetector(
      onTap: onClose,
      child: Container(
        color: Colors.black.withValues(alpha: 0.4),
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () {},
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
            decoration: BoxDecoration(color: g.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
            padding: const EdgeInsets.all(Go.sp6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(head, style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w700, color: g.onSurface)),
                if (zh.isNotEmpty) Text(zh, style: TextStyle(fontSize: Go.fsBody, color: g.onSurface3)),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: Go.sp4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final o in list)
                          GestureDetector(
                            onTap: () => onOpenArticle(Map<String, dynamic>.from(o as Map)),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: Go.sp4),
                              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: g.outline, width: 0.5))),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${o['sourceLabel'] ?? '来源'} · ${o['articleTitle'] ?? ''}',
                                      style: TextStyle(fontSize: Go.fsMeta, color: g.primary, fontWeight: FontWeight.w600)),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text('“${o['sentence']}”', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface, height: 1.5)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text('回到原文 ›', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (list.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: Go.sp4),
                            child: Text('暂无原文出处', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface3)),
                          ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(Go.sp3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: g.primary, borderRadius: BorderRadius.circular(Go.rFull)),
                    child: Text('关闭', style: TextStyle(fontSize: Go.fsBody, color: g.onPrimary)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
