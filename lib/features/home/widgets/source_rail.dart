import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 来源筛选条：「全部」+ 由累计 items 汇总的 source。
class HomeSourceRail extends StatelessWidget {
  final List<String> sources;
  final String? selected;
  final ValueChanged<String?> onPick;

  const HomeSourceRail({super.key, required this.sources, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip(context, '全部', selected == null, () => onPick(null)),
          for (final s in sources) ...[
            const SizedBox(width: Go.sp2),
            _chip(context, s, selected == s, () => onPick(s)),
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
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: Go.r(320)),
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
      ),
    );
  }
}
