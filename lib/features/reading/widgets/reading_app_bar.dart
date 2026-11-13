import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 阅读器顶栏：返回 / 多选 / 朗读 / AI 精选 / 阅读设置。
class ReadingAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final GoReaderPalette pal;
  final bool selectMode;
  final bool ttsBusy;
  final bool useCurated;
  final bool settingsOpen;
  final VoidCallback onToggleSelect;
  final VoidCallback onToggleTts;
  final VoidCallback onCurate;
  final VoidCallback onToggleSettings;

  const ReadingAppBar({
    super.key,
    required this.title,
    required this.pal,
    required this.selectMode,
    required this.ttsBusy,
    required this.useCurated,
    required this.settingsOpen,
    required this.onToggleSelect,
    required this.onToggleTts,
    required this.onCurate,
    required this.onToggleSettings,
  });

  @override
  Size get preferredSize => const Size.fromHeight(Go.appbarH);

  @override
  Widget build(BuildContext context) {
    return GoAppBar(
      title: title.isNotEmpty ? title : '文章阅读',
      style: GoAppBarStyle.floating,
      surface: pal.surface,
      titleColor: pal.ink,
      borderColor: pal.divider,
      shadow: const [], // 无投影：融入阅读面，滚动时不出现硬边
      leading: GoBack(onTap: () => Navigator.of(context).maybePop(), surface: pal.card, iconColor: pal.ink),
      actions: [
        GoIconBtn(icon: 'menu', onTap: onToggleSelect, color: selectMode ? pal.accent : pal.secondary),
        GoIconBtn(icon: ttsBusy ? 'stop' : 'tts', onTap: onToggleTts, color: ttsBusy ? pal.accent : pal.secondary),
        GoIconBtn(icon: 'sparkle', onTap: onCurate, color: useCurated ? pal.accent : pal.secondary),
        GoIconBtn(icon: 'settings', onTap: onToggleSettings, color: settingsOpen ? pal.accent : pal.secondary),
      ],
    );
  }
}
