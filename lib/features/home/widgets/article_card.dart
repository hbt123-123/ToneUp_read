import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 首页文章卡片：中文标题 / 英文标题 / 元信息 + 右侧来源胶囊与「已缓存」小标。
class HomeArticleCard extends StatelessWidget {
  final Map<String, dynamic> item;

  /// 英文标题 → 中文标题（没有则为 null）。
  final String? zhTitle;
  final bool cached;
  final VoidCallback onTap;

  const HomeArticleCard({
    super.key,
    required this.item,
    required this.zhTitle,
    required this.cached,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final en = (item['title'] ?? '').toString().trim();
    final zh = en.isEmpty ? null : zhTitle;
    final zhText = (zh == null || zh.trim().isEmpty) ? (en.isEmpty ? '未命名文章' : en) : zh.trim();
    // 没拿到中文时首行已经是英文，第二行不再重复展示。
    final showEn = zh != null && zh.trim().isNotEmpty && en.isNotEmpty;
    final source = (item['source'] ?? '').toString().trim();

    return Container(
      margin: const EdgeInsets.only(bottom: Go.sp3),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 4,
            bottom: 4,
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: g.primary,
                borderRadius: BorderRadius.circular(Go.rFull),
              ),
            ),
          ),
          GoCard(
            // 列表项关掉毛玻璃：滚动列表里几十个 BackdropFilter 会持续重建模糊层，
            // 而卡片底色本身接近不透明，视觉上看不出差别。
            blur: false,
            padding: const EdgeInsets.fromLTRB(Go.sp3, Go.sp5, Go.sp4, Go.sp5),
            onTap: onTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zhText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Go.fsH2,
                          fontWeight: FontWeight.w600,
                          height: Go.lhSnug,
                          color: g.onSurface,
                        ),
                      ),
                      if (showEn) ...[
                        const SizedBox(height: Go.sp2),
                        Text(
                          en,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Go.fsBodySm,
                            height: Go.lhSnug,
                            color: g.onSurface3,
                          ),
                        ),
                      ],
                      const SizedBox(height: Go.sp3),
                      Text(
                        _metaOf(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Go.sp3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (source.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
                        decoration: BoxDecoration(
                          color: g.primary90,
                          borderRadius: BorderRadius.circular(Go.rFull),
                          border: Border.all(color: g.primary.withValues(alpha: 0.35), width: 0.5),
                        ),
                        child: Text(
                          source,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Go.fsCap,
                            fontWeight: FontWeight.w600,
                            color: g.primary,
                          ),
                        ),
                      ),
                    if (cached) ...[
                      const SizedBox(height: Go.sp2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
                        decoration: BoxDecoration(
                          color: g.success.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(Go.rFull),
                          border: Border.all(color: g.success.withValues(alpha: 0.40), width: 0.5),
                        ),
                        child: Text(
                          '已缓存',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: g.success),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 接口返回秒、本地列存毫秒：小于 1e11 视作秒，统一成毫秒后 .toLocal()。
  static DateTime? _dateOf(Object? v) {
    if (v is! num) return null;
    var ms = v.toInt();
    if (ms <= 0) return null;
    if (ms < 100000000000) ms *= 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  static String _metaOf(Map<String, dynamic> it) {
    final parts = <String>[];
    final wc = it['word_count'];
    if (wc is num && wc > 0) parts.add('${wc.toInt()} 词');
    final d = _dateOf(it['published_at']);
    if (d != null) parts.add('${_two(d.month)}-${_two(d.day)}');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}
