import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_icon.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 「最近阅读」卡：上次读到的那篇文章 + 进度条，点击从上次段落继续。
/// 数据是 DB 行（camelCase 列：title/wordCount/publishedAt/lastPara/readProgress），
/// 与云端 items 的 snake_case 不同。
class HomeContinueCard extends StatelessWidget {
  final Map<String, dynamic> row;

  /// 英文标题 → 中文标题（没有则为 null）。
  final String? zhTitle;
  final VoidCallback onTap;

  const HomeContinueCard({
    super.key,
    required this.row,
    required this.zhTitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final en = '${row['title'] ?? ''}'.trim();
    final zh = (zhTitle == null || zhTitle!.trim().isEmpty) ? null : zhTitle!.trim();
    final title = zh ?? (en.isEmpty ? '未命名文章' : en);
    final progress = (row['readProgress'] is num ? (row['readProgress'] as num).toDouble() : 0.0).clamp(0.0, 1.0);
    final source = '${row['source'] ?? ''}'.trim();
    final when = _whenOf(row['lastOpenedAt'] as num?);

    final meta = <String>[
      // floor：0.995+ 四舍五入会显示「已读 100%」但并未读到末段。
      if (progress > 0.001) '已读 ${(progress * 100).floor()}%',
      if (source.isNotEmpty) source,
      if (when.isNotEmpty) when,
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp4),
      child: GoCard(
        blur: false,
        padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp5, Go.sp4, Go.sp5),
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: Go.r(72),
              height: Go.r(72),
              decoration: BoxDecoration(color: g.primary95, borderRadius: BorderRadius.circular(Go.rSm)),
              child: Center(child: GoIcon('book', size: Go.r(44), color: g.primary)),
            ),
            const SizedBox(width: Go.sp4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: Go.fsH2, fontWeight: FontWeight.w600, height: Go.lhSnug, color: g.onSurface),
                  ),
                  const SizedBox(height: Go.sp3),
                  GoProgress(value: progress),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: Go.sp2),
                    Text(
                      meta.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Go.sp2),
            GoIcon('chevron-right', size: Go.fsBody, color: g.onSurface3),
          ],
        ),
      ),
    );
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  /// lastOpenedAt（epoch 毫秒）→ 今天 / 昨天 / MM-dd。
  static String _whenOf(num? ms) {
    if (ms == null || ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt()).toLocal();
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    return '${_two(d.month)}-${_two(d.day)}';
  }
}
