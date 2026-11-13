import 'package:flutter/material.dart';
import 'go_tokens.dart';

/// 明暗两套 Material 主题：颜色全部来自 [GoPalette]，并注册成 ThemeExtension，
/// 页面组件用 `GoPalette.of(context)` 取色（不再引用固定的深色常量）。
ThemeData _buildTheme(Brightness brightness) {
  final pal = brightness == Brightness.dark ? GoPalette.dark : GoPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: pal.primary,
    onPrimary: pal.onPrimary,
    primaryContainer: pal.primary95,
    onPrimaryContainer: pal.onPrimaryContainer,
    secondary: pal.secondary,
    onSecondary: pal.onSecondary,
    secondaryContainer: pal.secondaryContainer,
    onSecondaryContainer: pal.onSecondaryContainer,
    tertiary: pal.tertiary,
    onTertiary: pal.onTertiary,
    tertiaryContainer: pal.tertiaryContainer,
    onTertiaryContainer: pal.onTertiaryContainer,
    error: pal.error,
    onError: pal.onDanger,
    surface: pal.surface,
    onSurface: pal.onSurface,
    surfaceContainerHighest: pal.surface2,
    onSurfaceVariant: pal.onSurface2,
    outline: pal.outline,
    outlineVariant: pal.surfaceVariant,
    shadow: const Color(0xFF000000),
    scrim: pal.scrim,
    inverseSurface: pal.onSurface,
    onInverseSurface: pal.surface,
    inversePrimary: pal.primary20,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: pal.bg,
    splashFactory: InkRipple.splashFactory,
    extensions: [pal],
    appBarTheme: AppBarTheme(
      backgroundColor: pal.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: pal.onSurface,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: pal.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Go.rLg)),
    ),
    dividerColor: pal.outline,
    dividerTheme: DividerThemeData(color: pal.outline, thickness: 0.5, space: 0.5),
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: Go.fsBodySm, height: Go.lhNormal, color: pal.onSurface),
      bodyLarge: TextStyle(fontSize: Go.fsBody, height: Go.lhNormal, color: pal.onSurface),
      titleMedium: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: pal.onSurface),
      titleSmall: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w500, color: pal.onSurface),
      labelMedium: TextStyle(fontSize: Go.fsMeta, color: pal.onSurface3),
      labelSmall: TextStyle(fontSize: Go.fsCap, color: pal.onSurface3),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
  );
}

ThemeData buildLightTheme() => _buildTheme(Brightness.light);
ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

/// 在任意 BuildContext 上取语义 token 的便捷扩展。
extension GoColorExt on BuildContext {
  ColorScheme get go => Theme.of(this).colorScheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// 当前主题色板（等价于 `GoPalette.of(context)`）。
  GoPalette get gp => GoPalette.of(this);
}
