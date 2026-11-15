import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 来源筛选条：「全部」+ 已加载文章出现过的来源（横向滚动）。
class HomeSourceRail extends StatelessWidget {
  final List<String> sources;
  final String? selected; // null = 全部
  final ValueChanged<String?> onPick;

  const HomeSourceRail({super.key, required this.sources, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip(context, '全部', selected == null, () => onPick(null)),
          for (final s in sources) ...[
            const SizedBox(width: Go.sp2),
            _chip(context, s, selected == s, () => onPick(selected == s ? null : s)),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, bool on, VoidCallback onTap) {
    final g = GoPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
        decoration: BoxDecoration(
          color: on ? g.primary : g.glassBg,
          borderRadius: BorderRadius.circular(Go.rFull),
          border: on ? null : Border.all(color: g.glassBorder, width: 0.5),
          boxShadow: g.elev1,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: Go.fsBodySm,
            fontWeight: FontWeight.w600,
            color: on ? g.onPrimary : g.onSurface2,
          ),
        ),
      ),
    );
  }
}
