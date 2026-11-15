import 'package:flutter/material.dart';

/// 设计令牌：**尺寸 / 字号 / 行高 / 圆角 / 布局**（与明暗主题无关）。
///
/// 颜色不在这里——统一走 [GoPalette]（ThemeExtension），页面用
/// `GoPalette.of(context)` 取当前主题的语义色。这样明暗两套主题才是真的。
class Go {
  Go._();

  /// rpx → dp。
  static double r(num rpx) => rpx * 0.5;

  /// 标题字体：未显式选择字体时用衬线，其余沿用正文字体 id。
  static String titleFont(String readerFont) => readerFont.isEmpty ? 'serif' : readerFont;

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
  static const glassRadius = 10.0;

  // ================= 布局 =================
  static const contentMax = 380.0; // 760rpx
  static const appbarH = 52.0; // 104rpx
  static const navH = 55.0; // 110rpx
}

/// 主题语义色板：深色「炭墨」与浅色「暖白」两套——保色相、低饱和，
/// 安静阅读器的底子：主色灰紫、辅色灰青/灰玫瑰，不再使用霓虹高饱和色。
///
/// 通过 `ThemeData.extensions` 注册，任意页面用 [GoPalette.of] 取当前值；
/// 没有注册主题的测试环境自动回落到 [dark]。
@immutable
class GoPalette extends ThemeExtension<GoPalette> {
  // —— 主色系 ——
  final Color primary;
  final Color primary95; // 选中态浅底
  final Color primary90;
  final Color primary80;
  final Color primary60;
  final Color primary40;
  final Color primary20;
  final Color onPrimary;
  final Color onPrimaryContainer;

  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;

  final Color tertiary;
  final Color onTertiary;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;

  // —— 中性 / 表面 ——
  final Color bg;
  final Color surface;
  final Color surface1;
  final Color surface2;
  final Color surfaceVariant;
  final Color surfaceRaised;
  final Color onSurface;
  final Color onSurface2;
  final Color onSurface3;
  final Color onSurfaceDisabled;
  final Color outline;
  final Color outlineStrong;
  final Color onBg;

  // —— 语义色 ——
  final Color success;
  final Color onSuccess;
  final Color warning;
  final Color onWarning;
  final Color danger;
  final Color onDanger;
  final Color error;
  final Color info;

  // —— 选中态 / 强调 ——
  final Color sel;
  final Color selStrong;
  final Color selWord;

  // —— 玻璃层 ——
  final Color glassBg;
  final Color glassBgStrong;
  final Color glassBorder;

  // —— 阴影 ——
  final List<BoxShadow> elev1;
  final List<BoxShadow> elev2;
  final List<BoxShadow> shadow3;
  final List<BoxShadow> navShadow;
  final List<BoxShadow> glassShadow;

  // —— 遮罩 ——
  final Color scrim;
  final Color overlay;

  const GoPalette({
    required this.primary,
    required this.primary95,
    required this.primary90,
    required this.primary80,
    required this.primary60,
    required this.primary40,
    required this.primary20,
    required this.onPrimary,
    required this.onPrimaryContainer,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.bg,
    required this.surface,
    required this.surface1,
    required this.surface2,
    required this.surfaceVariant,
    required this.surfaceRaised,
    required this.onSurface,
    required this.onSurface2,
    required this.onSurface3,
    required this.onSurfaceDisabled,
    required this.outline,
    required this.outlineStrong,
    required this.onBg,
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.onWarning,
    required this.danger,
    required this.onDanger,
    required this.error,
    required this.info,
    required this.sel,
    required this.selStrong,
    required this.selWord,
    required this.glassBg,
    required this.glassBgStrong,
    required this.glassBorder,
    required this.elev1,
    required this.elev2,
    required this.shadow3,
    required this.navShadow,
    required this.glassShadow,
    required this.scrim,
    required this.overlay,
  });

  /// 深色：中性炭底（去紫调）+ 低饱和灰紫强调。
  static const dark = GoPalette(
    primary: Color(0xFF8273AD),
    primary95: Color(0xFF28242F),
    primary90: Color(0xFF322E3C),
    primary80: Color(0xFF443F52),
    primary60: Color(0xFF6C6190),
    primary40: Color(0xFF8273AD),
    primary20: Color(0xFF504A61),
    onPrimary: Color(0xFF17141F),
    onPrimaryContainer: Color(0xFFDCD8E8),
    secondary: Color(0xFF7FA8A3),
    onSecondary: Color(0xFF10201D),
    secondaryContainer: Color(0xFF243330),
    onSecondaryContainer: Color(0xFFC3D5D1),
    tertiary: Color(0xFFB08494),
    onTertiary: Color(0xFF241318),
    tertiaryContainer: Color(0xFF38262C),
    onTertiaryContainer: Color(0xFFECD3DB),
    bg: Color(0xFF141317),
    surface: Color(0xFF1B1A1E),
    surface1: Color(0xFF212025),
    surface2: Color(0xFF29282D),
    surfaceVariant: Color(0xFF313036),
    surfaceRaised: Color(0xFF1E1D22),
    onSurface: Color(0xFFE9E7E4),
    onSurface2: Color(0xFFACA9A4),
    onSurface3: Color(0xFF807D78),
    onSurfaceDisabled: Color(0xFF585652),
    outline: Color(0xFF3A393F),
    outlineStrong: Color(0xFF525156),
    onBg: Color(0xFFE9E7E4),
    success: Color(0xFF7AA98C),
    onSuccess: Color(0xFF12211A),
    warning: Color(0xFFC2A45E),
    onWarning: Color(0xFF241D0A),
    danger: Color(0xFFC08578),
    onDanger: Color(0xFF2A1512),
    error: Color(0xFFC08578),
    info: Color(0xFF7FA8A3),
    sel: Color(0x2E8273AD),
    selStrong: Color(0x4D8273AD),
    selWord: Color(0x4DB08494),
    glassBg: Color(0xBF1C1B20),
    glassBgStrong: Color(0xE6201F25),
    glassBorder: Color(0x33FFFFFF),
    elev1: [
      BoxShadow(color: Color(0x40000000), offset: Offset(0, 0.5), blurRadius: 1),
      BoxShadow(color: Color(0x55000000), offset: Offset(0, 1), blurRadius: 3),
    ],
    elev2: [
      BoxShadow(color: Color(0x55000000), offset: Offset(0, 1), blurRadius: 3),
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 4), blurRadius: 10),
    ],
    shadow3: [
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 3), blurRadius: 8),
      BoxShadow(color: Color(0x73000000), offset: Offset(0, 8), blurRadius: 18),
    ],
    navShadow: [
      BoxShadow(color: Color(0x99000000), offset: Offset(0, -2), blurRadius: 12),
    ],
    glassShadow: [
      BoxShadow(color: Color(0x33000000), offset: Offset(0, 6), blurRadius: 18),
      BoxShadow(color: Color(0x40000000), offset: Offset(0, 2), blurRadius: 6),
    ],
    scrim: Color(0x99000000),
    overlay: Color(0xD1201F25),
  );

  /// 浅色：暖白底 + 低饱和灰紫强调；阴影轻、玻璃近白。
  static const light = GoPalette(
    primary: Color(0xFF6E639A),
    primary95: Color(0xFFEFEDF6),
    primary90: Color(0xFFE2DFEC),
    primary80: Color(0xFFCDC9DD),
    primary60: Color(0xFF8F84B0),
    primary40: Color(0xFF6E639A),
    primary20: Color(0xFFB0A9C6),
    onPrimary: Color(0xFFFFFFFF),
    onPrimaryContainer: Color(0xFF29243C),
    secondary: Color(0xFF437C75),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDCE7E3),
    onSecondaryContainer: Color(0xFF1D332F),
    tertiary: Color(0xFF9D5F78),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFEBDAE0),
    onTertiaryContainer: Color(0xFF3A212B),
    bg: Color(0xFFFAF8F4),
    surface: Color(0xFFFFFFFF),
    surface1: Color(0xFFF4F1EB),
    surface2: Color(0xFFEDEAE3),
    surfaceVariant: Color(0xFFE5E2DA),
    surfaceRaised: Color(0xFFFFFFFF),
    onSurface: Color(0xFF24221E),
    onSurface2: Color(0xFF55524B),
    onSurface3: Color(0xFF84817A),
    onSurfaceDisabled: Color(0xFFB6B3AB),
    outline: Color(0xFFE2DFD7),
    outlineStrong: Color(0xFFC9C5BB),
    onBg: Color(0xFF24221E),
    success: Color(0xFF4F7D63),
    onSuccess: Color(0xFFFFFFFF),
    warning: Color(0xFF9A7B2F),
    onWarning: Color(0xFFFFFFFF),
    danger: Color(0xFFA05A54),
    onDanger: Color(0xFFFFFFFF),
    error: Color(0xFFA05A54),
    info: Color(0xFF437C75),
    sel: Color(0x246E639A),
    selStrong: Color(0x3D6E639A),
    selWord: Color(0x3D9D5F78),
    glassBg: Color(0xE6FFFFFF),
    glassBgStrong: Color(0xF2FFFFFF),
    glassBorder: Color(0x14000000),
    elev1: [
      BoxShadow(color: Color(0x0F000000), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 4),
    ],
    elev2: [
      BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 4),
      BoxShadow(color: Color(0x1F000000), offset: Offset(0, 4), blurRadius: 12),
    ],
    shadow3: [
      BoxShadow(color: Color(0x1F000000), offset: Offset(0, 3), blurRadius: 8),
      BoxShadow(color: Color(0x26000000), offset: Offset(0, 8), blurRadius: 20),
    ],
    navShadow: [
      BoxShadow(color: Color(0x1F000000), offset: Offset(0, -2), blurRadius: 12),
    ],
    glassShadow: [
      BoxShadow(color: Color(0x14000000), offset: Offset(0, 6), blurRadius: 18),
      BoxShadow(color: Color(0x0F000000), offset: Offset(0, 2), blurRadius: 6),
    ],
    scrim: Color(0x66000000),
    overlay: Color(0xF2FFFFFF),
  );

  /// 取当前主题色板；未注册扩展（纯组件测试）时回落深色。
  static GoPalette of(BuildContext context) =>
      Theme.of(context).extension<GoPalette>() ?? dark;

  @override
  GoPalette copyWith({Color? primary, Color? bg, Color? surface, Color? onSurface}) => GoPalette(
        primary: primary ?? this.primary,
        primary95: primary95,
        primary90: primary90,
        primary80: primary80,
        primary60: primary60,
        primary40: primary40,
        primary20: primary20,
        onPrimary: onPrimary,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondary,
        onSecondary: onSecondary,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        tertiary: tertiary,
        onTertiary: onTertiary,
        tertiaryContainer: tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer,
        bg: bg ?? this.bg,
        surface: surface ?? this.surface,
        surface1: surface1,
        surface2: surface2,
        surfaceVariant: surfaceVariant,
        surfaceRaised: surfaceRaised,
        onSurface: onSurface ?? this.onSurface,
        onSurface2: onSurface2,
        onSurface3: onSurface3,
        onSurfaceDisabled: onSurfaceDisabled,
        outline: outline,
        outlineStrong: outlineStrong,
        onBg: onBg,
        success: success,
        onSuccess: onSuccess,
        warning: warning,
        onWarning: onWarning,
        danger: danger,
        onDanger: onDanger,
        error: error,
        info: info,
        sel: sel,
        selStrong: selStrong,
        selWord: selWord,
        glassBg: glassBg,
        glassBgStrong: glassBgStrong,
        glassBorder: glassBorder,
        elev1: elev1,
        elev2: elev2,
        shadow3: shadow3,
        navShadow: navShadow,
        glassShadow: glassShadow,
        scrim: scrim,
        overlay: overlay,
      );

  @override
  GoPalette lerp(covariant GoPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    List<BoxShadow> s(List<BoxShadow> a, List<BoxShadow> b) => t < 0.5 ? a : b;
    return GoPalette(
      primary: l(primary, other.primary),
      primary95: l(primary95, other.primary95),
      primary90: l(primary90, other.primary90),
      primary80: l(primary80, other.primary80),
      primary60: l(primary60, other.primary60),
      primary40: l(primary40, other.primary40),
      primary20: l(primary20, other.primary20),
      onPrimary: l(onPrimary, other.onPrimary),
      onPrimaryContainer: l(onPrimaryContainer, other.onPrimaryContainer),
      secondary: l(secondary, other.secondary),
      onSecondary: l(onSecondary, other.onSecondary),
      secondaryContainer: l(secondaryContainer, other.secondaryContainer),
      onSecondaryContainer: l(onSecondaryContainer, other.onSecondaryContainer),
      tertiary: l(tertiary, other.tertiary),
      onTertiary: l(onTertiary, other.onTertiary),
      tertiaryContainer: l(tertiaryContainer, other.tertiaryContainer),
      onTertiaryContainer: l(onTertiaryContainer, other.onTertiaryContainer),
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surface1: l(surface1, other.surface1),
      surface2: l(surface2, other.surface2),
      surfaceVariant: l(surfaceVariant, other.surfaceVariant),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      onSurface: l(onSurface, other.onSurface),
      onSurface2: l(onSurface2, other.onSurface2),
      onSurface3: l(onSurface3, other.onSurface3),
      onSurfaceDisabled: l(onSurfaceDisabled, other.onSurfaceDisabled),
      outline: l(outline, other.outline),
      outlineStrong: l(outlineStrong, other.outlineStrong),
      onBg: l(onBg, other.onBg),
      success: l(success, other.success),
      onSuccess: l(onSuccess, other.onSuccess),
      warning: l(warning, other.warning),
      onWarning: l(onWarning, other.onWarning),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      error: l(error, other.error),
      info: l(info, other.info),
      sel: l(sel, other.sel),
      selStrong: l(selStrong, other.selStrong),
      selWord: l(selWord, other.selWord),
      glassBg: l(glassBg, other.glassBg),
      glassBgStrong: l(glassBgStrong, other.glassBgStrong),
      glassBorder: l(glassBorder, other.glassBorder),
      elev1: s(elev1, other.elev1),
      elev2: s(elev2, other.elev2),
      shadow3: s(shadow3, other.shadow3),
      navShadow: s(navShadow, other.navShadow),
      glassShadow: s(glassShadow, other.glassShadow),
      scrim: l(scrim, other.scrim),
      overlay: l(overlay, other.overlay),
    );
  }
}

// =====================================================================
// 阅读页配色：深色降眩光（night，默认）/ 暖纸色（paper）
// 正文长时间阅读面专用——与 App 明暗主题相互独立。
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

  /// 强调色（night 沿用主色；paper 用更深的紫保证浅底可读）。
  final Color accent;

  /// 词选中高亮底色。
  final Color sel;

  /// 错误/危险色（paper 上需要比 danger 更深才可读）。
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
    accent: Color(0xFF8B5CF6),
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
