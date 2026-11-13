import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_icon.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 未内置文章接口密钥时的提示横幅（正常发布版不会出现）。
class HomeKeyBanner extends StatelessWidget {
  const HomeKeyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, 0),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp3, Go.sp4, Go.sp3),
      decoration: BoxDecoration(
        color: g.primary90,
        borderRadius: BorderRadius.circular(Go.rMd),
        border: Border.all(color: g.primary.withValues(alpha: 0.45), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GoIcon('settings', size: 16, color: g.primary),
          const SizedBox(width: Go.sp3),
          Expanded(
            child: Text(
              '本应用未内置文章接口密钥，暂时无法加载文章',
              style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 离线兜底横幅。
class HomeOfflineBanner extends StatelessWidget {
  final VoidCallback onRetry;
  const HomeOfflineBanner({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, 0),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp3, Go.sp3, Go.sp3),
      decoration: BoxDecoration(
        color: g.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Go.rMd),
        border: Border.all(color: g.warning.withValues(alpha: 0.32), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GoIcon('warning', size: 16, color: g.onWarning),
          const SizedBox(width: Go.sp3),
          Expanded(
            child: Text(
              '网络不可用，显示已缓存',
              style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface, height: 1.5),
            ),
          ),
          const SizedBox(width: Go.sp3),
          GestureDetector(
            onTap: onRetry,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Go.sp2, vertical: Go.sp1),
              child: Text(
                '重试',
                style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w700, color: g.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 缓存正文时的全屏遮罩。
class HomeOpeningOverlay extends StatelessWidget {
  const HomeOpeningOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      color: g.scrim,
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp10, vertical: Go.sp8),
        decoration: BoxDecoration(
          color: g.surfaceRaised,
          borderRadius: BorderRadius.circular(Go.rLg),
          boxShadow: g.shadow3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PolySpinner(),
            const SizedBox(height: Go.sp4),
            Text(
              '缓存正文…',
              style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface2, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
