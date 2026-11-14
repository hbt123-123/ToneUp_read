import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_icon.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 精选大卡（Apple Books 封面位）：程序化渐变封面 + 标题区。
///
/// 接口没有图片字段，封面用纯程序化绘制：固定高度的渐变背景（装饰圆 + 来源水印，
/// 均非正文文字，允许固定高度）+ 下方标题区（文字一律 maxLines，textScaler 铁律）。
class HomeFeaturedCard extends StatelessWidget {
  final Map<String, dynamic> item;

  /// 英文标题 → 中文标题（没有则为 null）。
  final String? zhTitle;
  final bool cached;
  final VoidCallback onTap;

  const HomeFeaturedCard({
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
    final zh = (zhTitle == null || zhTitle!.trim().isEmpty) ? null : zhTitle!.trim();
    final zhText = zh ?? (en.isEmpty ? '未命名文章' : en);
    final showEn = zh != null && en.isNotEmpty;
    final source = (item['source'] ?? '').toString().trim();

    // 渐变按 guid 稳定取一组品牌色对：同一天同一篇文章的封面不变。
    final colors = _gradientOf('${item['url'] ?? item['id'] ?? ''}', g);

    return Container(
      margin: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp4),
      child: GoCard(
        blur: false,
        padding: EdgeInsets.zero,
        radius: Go.rXl,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cover(context, colors, source),
            Padding(
              padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp4, Go.sp5, Go.sp5),
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
                      style: TextStyle(fontSize: Go.fsBodySm, height: Go.lhSnug, color: g.onSurface3),
                    ),
                  ],
                  const SizedBox(height: Go.sp3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _metaOf(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3),
                        ),
                      ),
                      if (cached) ...[
                        const SizedBox(width: Go.sp2),
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
      ),
    );
  }

  /// 封面区：固定高度渐变背景 + 装饰圆 + 来源大写水印 + 「今日精选」角标。
  /// 背景与装饰允许固定尺寸；水印文字用 maxLines/clip（textScaler 放大也不溢出）。
  Widget _cover(BuildContext context, List<Color> colors, String source) {
    final g = GoPalette.of(context);
    return Container(
      height: 150,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl)),
        child: Stack(
          children: [
            // 装饰圆：纯背景形状。
            Positioned(
              right: -36,
              top: -36,
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.10)),
              ),
            ),
            Positioned(
              right: 46,
              bottom: -30,
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            // 来源水印：右下大写字，低透明度装饰字。
            if (source.isNotEmpty)
              Positioned(
                right: Go.sp5,
                bottom: Go.sp3,
                child: Text(
                  source.toUpperCase(),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: Go.fsDisplay,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
            ),
            // 「今日精选」角标。
            Positioned(
              left: Go.sp5,
              top: Go.sp5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(Go.rFull),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.30), width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GoIcon('sparkle', size: Go.fsCap + 2, color: Colors.white),
                    const SizedBox(width: Go.sp1),
                    Text(
                      '今日精选',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 三组品牌内渐变色对，按 [seed] 稳定散列选取（跨运行一致）。
  static List<Color> _gradientOf(String seed, GoPalette g) {
    var h = 0;
    for (var i = 0; i < seed.length; i++) {
      h = (h * 31 + seed.codeUnitAt(i)) & 0x7fffffff;
    }
    switch (h % 3) {
      case 0:
        return [g.primary, g.secondary];
      case 1:
        return [g.secondary, g.tertiary];
      default:
        return [g.tertiary, g.primary];
    }
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
    final src = '${it['source'] ?? ''}'.trim();
    if (src.isNotEmpty) parts.add(src);
    final wc = it['word_count'];
    if (wc is num && wc > 0) parts.add('${wc.toInt()} 词');
    final d = _dateOf(it['published_at']);
    if (d != null) parts.add('${_two(d.month)}-${_two(d.day)}');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}
