import 'package:flutter/material.dart';


class Go {
  Go._();

  /// rpx → dp。
  static double r(num rpx) => rpx * 0.5;

  // ================= 主色系（霓虹紫 Berry 盘 · 深色玻璃） =================
  static const primary = Color(0xFF8B5CF6); // 霓虹紫（白字可读）
  static const primary95 = Color(0xFF241A3A); // 选中态深紫底
  static const primary90 = Color(0xFF2E2350);
  static const primary80 = Color(0xFF3D2E66);
  static const primary60 = Color(0xFF6D4FC0);
  static const primary40 = Color(0xFF8B5CF6);
  static const primary20 = Color(0xFF4A2E84);
  static const onPrimary = Color(0xFFFFFFFF);
  static const onPrimaryVariant = Color(0xFF2D0A45);
  static const onPrimaryContainer = Color(0xFFE9DEFF);

  static const secondary = Color(0xFF41E0D0); // 青（渐变副色）
  static const onSecondary = Color(0xFF06231F);
  static const secondaryContainer = Color(0xFF163B39);
  static const onSecondaryContainer = Color(0xFFAEF2EA);

  static const tertiary = Color(0xFFE072B0); // 粉
  static const onTertiary = Color(0xFF2A0A1B);
  static const tertiaryContainer = Color(0xFF3A1730);
  static const onTertiaryContainer = Color(0xFFF6D6E9);

  // ================= 中性 / 表面（深色） =================
  static const bg = Color(0xFF0E0A1A); // 近黑紫底
  static const surface = Color(0xFF171327); // 卡片 / 面板
  static const surface1 = Color(0xFF1E1931);
  static const surface2 = Color(0xFF261F3D);
  static const surfaceVariant = Color(0xFF2E2647); // 进度轨道（暗但可见）
  static const surfaceRaised = Color(0xFF1B1530);
  static const onSurface = Color(0xFFECE9F5);
  static const onSurface2 = Color(0xFFB7AFCB);
  static const onSurface3 = Color(0xFF8A82A0);
  static const onSurfaceDisabled = Color(0xFF5C5675);
  static const outline = Color(0xFF3A3352);
  static const outlineStrong = Color(0xFF524A6E);
  static const onBg = Color(0xFFECE9F5);

  // ================= 语义色 =================
  static const success = Color(0xFF4CC38A);
  static const onSuccess = Color(0xFF06231A);
  static const warning = Color(0xFFE0B341);
  static const onWarning = Color(0xFF2A1F00);
  static const danger = Color(0xFFE072B0);
  static const onDanger = Color(0xFF2A0A1B);
  static const error = Color(0xFFE072B0);
  static const info = Color(0xFF41E0D0);

  // ================= 选中态 / 强调 =================
  static const sel = Color(0x2E8B5CF6); // rgba(139,92,246,.18)
  static const selStrong = Color(0x4D8B5CF6); // .30
  static const selWord = Color(0x4DE072B0); // .30

  static const glassBg = Color(0xBF1A1430);
  static const glassBgStrong = Color(0xE61E1838);
  static const glassBorder = Color(0x40FFFFFF);
  static const glassRadius = 10.0;

  static const List<BoxShadow> elev1 = [
    BoxShadow(color: Color(0x40000000), offset: Offset(0, 0.5), blurRadius: 1),
    BoxShadow(color: Color(0x55000000), offset: Offset(0, 1), blurRadius: 3),
  ];
  static const List<BoxShadow> elev2 = [
    BoxShadow(color: Color(0x55000000), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x66000000), offset: Offset(0, 4), blurRadius: 10),
  ];
  static const List<BoxShadow> shadow3 = [
    BoxShadow(color: Color(0x66000000), offset: Offset(0, 3), blurRadius: 8),
    BoxShadow(color: Color(0x73000000), offset: Offset(0, 8), blurRadius: 18),
  ];
  static const List<BoxShadow> navShadow = [
    BoxShadow(color: Color(0x99000000), offset: Offset(0, -2), blurRadius: 12),
  ];
  static const List<BoxShadow> glassShadow = [
    BoxShadow(color: Color(0x4D6D4FC0), offset: Offset(0, 6), blurRadius: 18),
    BoxShadow(color: Color(0x40000000), offset: Offset(0, 2), blurRadius: 6),
  ];
  static const List<BoxShadow> glowPrimary = [
    BoxShadow(color: Color(0x3D8B5CF6), blurRadius: 14, offset: Offset(0, 3)),
  ];
  static const List<BoxShadow> glowSecondary = [
    BoxShadow(color: Color(0x3341E0D0), blurRadius: 10, offset: Offset(0, 2)),
  ];

  static const scrim = Color(0x99000000);
  static const overlay = Color(0xD11E1838);

  // ================= 字体 =================
  static const fontRead = 'Songti SC'; // 阅读正文衬线（回退到系统衬线）
  static const fontMono = 'monospace';

  // ================= 字号 (rpx→dp) =================
  static const fsDisplay = 20.0; // 40
  static const fsH1 = 16.0; // 32
  static const fsH2 = 14.0; // 28
  static const fsTitle = 15.0; // 30
  static const fsBody = 15.0; // 30
  static const fsBodySm = 13.5; // 27
  static const fsLabel = 12.0; // 24
  static const fsMeta = 11.5; // 23
  static const fsCap = 10.5; // 21

  // ================= 行高 =================
  static const lhTight = 1.25;
  static const lhSnug = 1.4;
  static const lhNormal = 1.6;
  static const lhRelaxed = 1.75;

  // ================= 间距 (rpx→dp) =================
  static const sp1 = 2.0;
  static const sp2 = 4.0;
  static const sp3 = 6.0;
  static const sp4 = 8.0;
  static const sp5 = 10.0;
  static const sp6 = 12.0;
  static const sp8 = 16.0;
  static const sp10 = 20.0;
  static const sp12 = 24.0;
  static const sp16 = 32.0;

  // ================= 圆角 (rpx→dp) =================
  static const rXs = 4.0;
  static const rSm = 6.0;
  static const rMd = 8.0;
  static const rLg = 12.0;
  static const rXl = 16.0;
  static const rFull = 999.0;

  // ================= 布局 =================
  static const contentMax = 380.0; // 760rpx
  static const appbarH = 52.0; // 104rpx
  static const navH = 55.0; // 110rpx
}

// =====================================================================
// 阅读页配色：深色降眩光（night，默认）/ 暖纸色（paper）
// 正文长时间阅读面专用——不套 Go 的近白 ink，也不铺紫青光晕。
// =====================================================================
class GoReaderPalette {
  /// 页面底色（整页实色，正文背后不允许光晕）。
  final Color bg;

  /// 面板表面：顶栏 / 设置面板 / 选择模式提示条。
  final Color surface;

  /// 略抬升的小卡片：步进按钮、图片占位、「正文未缓存」卡。
  final Color card;

  /// 正文主 ink（对比度目标 ≈10:1，明显低于纯白眩光）。
  final Color ink;

  /// 次级文字（帮助语 / 词形 / 选区预览）。
  final Color secondary;

  /// 元信息小字（日期 / 分钟数 / 「全文完」）。
  final Color meta;

  /// 分隔线。
  final Color divider;

  /// 强调色（night 沿用 Go.primary；paper 用更深的紫保证浅底可读）。
  final Color accent;

  /// 词选中高亮底色。
  final Color sel;

  /// 错误/危险色（paper 上需要比 Go.danger 更深才可读）。
  final Color danger;

  /// 底部选区操作条（两种主题下都是「墨色卡片」，刻意压住背景）。
  final Color bar;
  final Color onBar;

  final bool isNight;

  const GoReaderPalette({
    required this.bg,
    required this.surface,
    required this.card,
    required this.ink,
    required this.secondary,
    required this.meta,
    required this.divider,
    required this.accent,
    required this.sel,
    required this.danger,
    required this.bar,
    required this.onBar,
    required this.isNight,
  });
}

class GoReader {
  GoReader._();

  /// 夜读：暖中性近黑底 + 柔灰紫 ink（≈11:1 对比，取代 #ECE9F5 的白茫茫）。
  static const night = GoReaderPalette(
    bg: Color(0xFF12101B),
    surface: Color(0xFF1A1727),
    card: Color(0xFF221E30),
    ink: Color(0xFFCFC8DC), // ≈11.5:1 on bg
    secondary: Color(0xFFA79FB8), // ≈7.5:1
    meta: Color(0xFF7F7791), // ≈4.4:1（小字元信息）
    divider: Color(0xFF2E2A3D),
    accent: Go.primary,
    sel: Color(0x4DE072B0),
    danger: Color(0xFFE072B0),
    bar: Color(0xFF241F2E),
    onBar: Color(0xFFECE9F5),
    isNight: true,
  );

  /// 纸色：暖纸底 + 暖深灰 ink（≈10:1 对比），强调紫加深到浅底可读。
  static const paper = GoReaderPalette(
    bg: Color(0xFFF3EBDD),
    surface: Color(0xFFEAE0CE),
    card: Color(0xFFE2D6C0),
    ink: Color(0xFF3B352C), // ≈10.3:1 on bg
    secondary: Color(0xFF6B6255), // ≈5.0:1
    meta: Color(0xFF746A5C), // ≈4.4:1
    divider: Color(0xFFD4C7B0),
    accent: Color(0xFF6D4FC0), // ≈5.0:1 on bg
    sel: Color(0x336D4FC0),
    danger: Color(0xFFB23B6E),
    bar: Color(0xFF3B352C),
    onBar: Color(0xFFF3EBDD),
    isNight: false,
  );

  /// AppConfigService.readerTheme → 调色板（未知值回落夜读）。
  static GoReaderPalette of(String theme) => theme == 'paper' ? paper : night;
}
