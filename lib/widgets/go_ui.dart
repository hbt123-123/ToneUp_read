import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_globe.dart';
import 'package:toneup_read/widgets/go_icon.dart';

// =====================================================================
// 背景：主题底色 + 紫青光晕（可选：程序化线框地球）
// =====================================================================
class GoBackdrop extends StatelessWidget {
  final Widget child;
  final bool globe;
  final bool globeActive;

  /// 非空时铺一层实色底、**不画光晕**（阅读面用，长文阅读不能有背景眩光）。
  final Color? surface;
  const GoBackdrop({super.key, required this.child, this.globe = false, this.globeActive = true, this.surface});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: surface ?? g.bg,
      child: Stack(
        children: [
          if (surface == null) ...[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.7, -0.9),
                    radius: 1.35,
                    colors: [g.primary.withValues(alpha: dark ? 0.55 : 0.14), g.primary.withValues(alpha: 0)],
                    stops: const [0, 0.65],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.95, 1.1),
                    radius: 1.4,
                    colors: [g.secondary.withValues(alpha: dark ? 0.45 : 0.10), g.secondary.withValues(alpha: 0)],
                    stops: const [0, 0.7],
                  ),
                ),
              ),
            ),
          ],
          if (globe) Positioned.fill(child: GoGlobe(active: globeActive)),
          child,
        ],
      ),
    );
  }
}

class GoGlowPulse extends StatefulWidget {
  final Widget child;
  final Color color;
  final double blur;
  const GoGlowPulse({super.key, required this.child, required this.color, this.blur = 14});
  @override
  State<GoGlowPulse> createState() => _GoGlowPulseState();
}

class _GoGlowPulseState extends State<GoGlowPulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);
  late final _a = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  /// 每 [_paintEvery] 帧才重绘一次：1.8s 的脉冲 20fps 已足够顺滑。
  /// 只动 alpha、固定 blurRadius（不改绘制边界/不重算模糊），再套 RepaintBoundary 隔离，
  /// 避免激活项脉冲每帧把底部导航（含全宽 BackdropFilter 玻璃层）一起重绘。
  static const _paintEvery = 3;
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  int _frames = 0;

  void _onFrame() {
    if (++_frames % _paintEvery == 0) _tick.value++;
  }

  @override
  void initState() {
    super.initState();
    _c.addListener(_onFrame);
  }

  @override
  void dispose() {
    _c.removeListener(_onFrame);
    _tick.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: _tick,
          child: widget.child,
          builder: (ctx, _, child) => DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.55 * _a.value),
                  blurRadius: widget.blur,
                ),
              ],
            ),
            child: child,
          ),
        ),
      );
}

class GoPage extends StatelessWidget {
  final Widget child;
  final bool navPad;
  final bool topPad;
  final EdgeInsetsGeometry? padding;
  final bool globe;
  final bool globeActive;

  /// 非空时替换整页底色并关闭光晕背景（阅读页用）。
  final Color? surface;
  const GoPage({super.key, required this.child, this.navPad = false, this.topPad = true, this.padding, this.globe = false, this.globeActive = true, this.surface});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: surface ?? GoPalette.of(context).bg,
      body: GoBackdrop(
        globe: globe,
        globeActive: globeActive,
        surface: surface,
        child: Padding(
          padding: padding ??
              EdgeInsets.only(
                top: topPad ? mq.padding.top : 0,
                bottom: navPad ? Go.navH + mq.padding.bottom + Go.sp4 : 0,
              ),
          child: child,
        ),
      ),
    );
  }
}

/// 内容容器：限宽 + 内边距（对齐 .go-content）
class GoContent extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const GoContent({super.key, required this.child, this.padding});
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Go.contentMax),
          child: Padding(padding: padding ?? const EdgeInsets.all(Go.sp4), child: child),
        ),
      );
}

// =====================================================================
// 顶栏 AppBar（对齐 .go-appbar）
// =====================================================================
enum GoAppBarStyle { normal, tonal, transparent, floating }

class GoAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  final Widget? leading;
  final GoAppBarStyle style;

  /// 以下四项默认沿用当前主题，仅阅读页等需要换肤的场景传入。
  final Color? surface;
  final Color? titleColor;
  final Color? borderColor;

  /// floating 样式的投影；传 const [] 表示无投影（融入阅读面）。
  final List<BoxShadow>? shadow;
  const GoAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
    this.style = GoAppBarStyle.normal,
    this.surface,
    this.titleColor,
    this.borderColor,
    this.shadow,
  });

  @override
  Size get preferredSize => const Size.fromHeight(Go.appbarH);

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final top = MediaQuery.of(context).padding.top;
    final tonal = style == GoAppBarStyle.tonal;
    final floating = style == GoAppBarStyle.floating;
    final transparent = style == GoAppBarStyle.transparent;
    return Container(
      padding: EdgeInsets.only(top: top + Go.sp2, left: Go.sp4, right: Go.sp4, bottom: Go.sp2),
      constraints: const BoxConstraints(minHeight: Go.appbarH + 24),
      decoration: BoxDecoration(
        color: transparent
            ? Colors.transparent
            : tonal
                ? (surface ?? g.primary95)
                : floating
                    ? (surface ?? g.surfaceRaised.withValues(alpha: 0.86))
                    : (surface ?? g.surfaceRaised),
        border: Border(
          bottom: BorderSide(
            color: borderColor ?? (transparent || tonal || floating ? Colors.transparent : g.outline),
            width: 0.5,
          ),
        ),
        boxShadow: floating ? (shadow ?? g.elev1) : null,
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Go.sp2)],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Go.fsTitle,
                fontWeight: FontWeight.w600,
                color: titleColor ?? g.onSurface,
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Row(mainAxisSize: MainAxisSize.min, children: _intersperse(actions, const SizedBox(width: Go.sp1))),
        ],
      ),
    );
  }
}

List<Widget> _intersperse(List<Widget> items, Widget sep) {
  final out = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    if (i > 0) out.add(sep);
    out.add(items[i]);
  }
  return out;
}

/// 圆形返回键（对齐 .back）
class GoBack extends StatelessWidget {
  const GoBack({super.key, this.onTap, this.surface, this.iconColor});
  final VoidCallback? onTap;

  /// 默认沿用当前主题；阅读页换肤时传入。
  final Color? surface;
  final Color? iconColor;
  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Material(
      color: surface ?? g.surface2,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: Go.r(72),
          height: Go.r(72),
          child: Center(child: GoIcon('arrow-left', size: Go.r(40), color: iconColor ?? g.onSurface)),
        ),
      ),
    );
  }
}

/// 图标按钮（对齐 .go-icon-btn，含 primary 玻璃质感变体）
class GoIconBtn extends StatefulWidget {
  final String icon;
  final VoidCallback? onTap;
  final bool primary;
  final double? size;
  final Color? color;
  final bool spin;
  const GoIconBtn({super.key, required this.icon, this.onTap, this.primary = false, this.size, this.color, this.spin = false});

  @override
  State<GoIconBtn> createState() => _GoIconBtnState();
}

class _GoIconBtnState extends State<GoIconBtn> {
  bool _down = false;

  void _press(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    if (v) HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final s = widget.size ?? Go.r(72);
    final tint = widget.primary ? g.primary : (widget.color ?? g.onSurface2);
    return AnimatedScale(
      scale: _down ? 0.86 : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: widget.onTap == null ? null : (_) => _press(true),
          onTapUp: widget.onTap == null ? null : (_) => _press(false),
          onTapCancel: () => _press(false),
          borderRadius: BorderRadius.circular(Go.rFull),
          splashColor: tint.withValues(alpha: 0.16),
          highlightColor: tint.withValues(alpha: 0.10),
          child: Container(
            width: s,
            height: s,
            decoration: widget.primary
                ? BoxDecoration(
                    color: g.primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                    border: Border.all(color: g.primary.withValues(alpha: 0.28)),
                    boxShadow: [BoxShadow(color: g.primary.withValues(alpha: 0.18), blurRadius: 8, offset: const Offset(0, 3))],
                  )
                : null,
            child: Center(
              child: GoIcon(widget.icon, size: s * 0.55, color: widget.primary ? g.primary : (widget.color ?? g.onSurface2), spin: widget.spin),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 区块标题（对齐 .go-section / .go-section__title）
// =====================================================================
class GoSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  const GoSection({super.key, this.title = '', required this.children, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Go.sp8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title.toUpperCase(),
                        style: TextStyle(
                          fontSize: Go.fsMeta,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.9,
                          color: GoPalette.of(context).onSurface3,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ...children,
          ],
        ),
      );
}

// =====================================================================
// 玻璃卡片（对齐 .go-card / .go-glass）
// =====================================================================
class GoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool flat;
  final double radius;
  final bool blur;
  const GoCard({super.key, required this.child, this.padding, this.onTap, this.flat = false, this.radius = Go.glassRadius, this.blur = true});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    Widget content = Container(
      padding: padding ?? const EdgeInsets.all(Go.sp5),
      decoration: BoxDecoration(
        color: flat ? g.glassBgStrong : g.glassBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: g.glassBorder, width: 0.5),
        boxShadow: flat ? null : g.glassShadow,
      ),
      child: child,
    );
    if (blur) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: content),
      );
    }
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: content),
      );
    }
    return content;
  }
}

// =====================================================================
// 列表行（对齐 .go-cell：图标 + 标题/副标题 + 右侧动作）
// =====================================================================
class GoListTile extends StatelessWidget {
  final String icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final bool divider;
  final bool highlight;

  /// 主色小圆点（有更新提示时用）。
  final bool dot;
  final bool spin;
  final Widget? trailing;

  const GoListTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.danger = false,
    this.divider = true,
    this.highlight = false,
    this.dot = false,
    this.spin = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Column(
      children: [
        if (divider) Divider(height: 0.5, thickness: 0.5, color: g.outline),
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp3),
            child: Row(
              children: [
                Container(
                  width: Go.r(64),
                  height: Go.r(64),
                  decoration: BoxDecoration(color: danger ? g.danger.withValues(alpha: 0.14) : g.primary95, borderRadius: BorderRadius.circular(Go.rSm)),
                  child: Center(child: GoIcon(icon, size: Go.r(48), color: danger ? g.danger : g.primary, spin: spin)),
                ),
                const SizedBox(width: Go.sp4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w500, color: danger ? g.error : g.onSurface)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 1),
                        Text(subtitle!, style: TextStyle(fontSize: Go.fsMeta, color: highlight ? g.primary : g.onSurface3)),
                      ],
                    ],
                  ),
                ),
                if (dot)
                  Container(
                    width: Go.sp4,
                    height: Go.sp4,
                    margin: const EdgeInsets.only(right: Go.sp2),
                    decoration: BoxDecoration(color: g.primary, shape: BoxShape.circle),
                  ),
                if (trailing != null) trailing else Icon(Icons.chevron_right, size: 18, color: g.onSurfaceDisabled),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// 按钮（对齐 .go-btn 及其变体）
// =====================================================================
enum GoBtnKind { filled, tonal, outlined, text }

class GoBtn extends StatelessWidget {
  final String label;
  final Widget? icon;
  final VoidCallback? onTap;
  final GoBtnKind kind;
  final bool block;
  final bool enabled;
  const GoBtn({super.key, required this.label, this.icon, this.onTap, this.kind = GoBtnKind.filled, this.block = false, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final Color fg = kind == GoBtnKind.filled ? (enabled ? g.onPrimary : g.onSurfaceDisabled) : g.primary;
    final Color bg = kind == GoBtnKind.filled
        ? (enabled ? g.primary : g.surface)
        : kind == GoBtnKind.tonal
            ? g.primary90
            : Colors.transparent;
    return SizedBox(
      width: block ? double.infinity : null,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(Go.rFull),
        child: InkWell(
          borderRadius: BorderRadius.circular(Go.rFull),
          onTap: enabled ? onTap : null,
          child: Container(
            height: Go.r(88),
            padding: EdgeInsets.symmetric(horizontal: kind == GoBtnKind.text ? Go.sp4 : Go.sp6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Go.rFull),
              border: kind == GoBtnKind.outlined ? Border.all(color: g.primary, width: 1) : null,
              boxShadow: kind == GoBtnKind.filled && enabled ? g.glowPrimary : null,
            ),
            child: Row(
              mainAxisSize: block ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[icon!, const SizedBox(width: Go.sp2)],
                Text(label, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// FAB（对齐 .go-fab）
// =====================================================================
class GoFab extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  const GoFab({super.key, this.label = '', this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final mq = MediaQuery.of(context);
    return Positioned(
      right: Go.sp6,
      bottom: Go.navH + mq.padding.bottom + Go.sp6,
      child: Material(
        color: g.surfaceRaised,
        borderRadius: BorderRadius.circular(Go.rFull),
        elevation: 4,
        child: InkWell(
          borderRadius: BorderRadius.circular(Go.rFull),
          onTap: onTap,
          child: Container(
            height: Go.r(96),
            padding: const EdgeInsets.symmetric(horizontal: Go.sp6),
            constraints: BoxConstraints(minWidth: Go.r(112)),
            decoration: BoxDecoration(border: Border.all(color: g.primary.withValues(alpha: 0.5), width: 1), borderRadius: BorderRadius.circular(Go.rFull)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[GoIcon(icon!, size: Go.r(40), color: g.primary), if (label.isNotEmpty) const SizedBox(width: Go.sp2)],
                if (label.isNotEmpty) Text(label, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: g.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 空状态（对齐 .go-empty）
// =====================================================================
class GoEmpty extends StatelessWidget {
  final String icon;
  final String title;
  final String? desc;
  final Widget? action;
  final bool primary;
  const GoEmpty({super.key, this.icon = 'search', required this.title, this.desc, this.action, this.primary = true});
  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Go.sp8, vertical: Go.sp16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: Go.r(128),
            height: Go.r(128),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary ? g.primary95 : g.surface2,
              shape: BoxShape.circle,
              border: primary ? Border.all(color: g.primary.withValues(alpha: 0.35), width: 1) : null,
            ),
            child: GoIcon(icon, size: Go.r(72), color: primary ? g.primary : g.onSurface3),
          ),
          const SizedBox(height: Go.sp5),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: g.onSurface)),
          if (desc != null) ...[
            const SizedBox(height: Go.sp2),
            Text(desc!, textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3, height: 1.6)),
          ],
          if (action != null) ...[const SizedBox(height: Go.sp6), action!],
        ],
      ),
    );
  }
}

// =====================================================================
// 骨架屏（对齐 .go-skeleton 微光）
// =====================================================================
class GoSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const GoSkeleton({super.key, this.width = double.infinity, required this.height, this.radius = Go.rMd});
  @override
  State<GoSkeleton> createState() => _GoSkeletonState();
}

class _GoSkeletonState extends State<GoSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(widget.radius)),
        clipBehavior: Clip.antiAlias,
        child: FractionallySizedBox(
          widthFactor: 0.5,
          alignment: Alignment(-1 + 3 * _c.value, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.transparent, (dark ? Colors.white : Colors.black).withValues(alpha: 0.08), Colors.transparent]),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 开关（对齐 .go-switch）
// =====================================================================
class GoSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const GoSwitch({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        width: Go.r(92),
        height: Go.r(52),
        padding: EdgeInsets.all(Go.r(6)),
        decoration: BoxDecoration(color: value ? g.primary : g.surfaceVariant, borderRadius: BorderRadius.circular(Go.rFull)),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: Go.r(40),
            height: Go.r(40),
            decoration: BoxDecoration(color: g.surfaceRaised, shape: BoxShape.circle, boxShadow: g.elev1),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 进度条（对齐 .go-progress）
// =====================================================================
class GoProgress extends StatelessWidget {
  final double value; // 0..1
  const GoProgress({super.key, required this.value});
  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Go.rFull),
      child: Container(
        height: Go.r(12),
        decoration: BoxDecoration(
          color: g.surfaceVariant,
          border: Border.all(color: g.outline, width: 0.5),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0, 1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 360),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [g.primary, g.secondary]),
                borderRadius: BorderRadius.circular(Go.rFull),
                boxShadow: [BoxShadow(color: g.secondary.withValues(alpha: 0.30), blurRadius: 8, offset: Offset.zero)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 表单输入（对齐 .go-field）
// =====================================================================
class GoField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final int maxLines;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  const GoField({super.key, this.controller, this.hint = '', this.maxLines = 1, this.obscure = false, this.onChanged, this.keyboardType});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return TextField(
      controller: controller,
      maxLines: maxLines,
      obscureText: obscure,
      onChanged: onChanged,
      keyboardType: keyboardType,
      style: TextStyle(fontSize: Go.fsBody, color: g.onSurface),
      cursorColor: g.primary,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: g.onSurfaceDisabled),
        filled: true,
        fillColor: g.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Go.rMd),
          borderSide: BorderSide(color: g.outline, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Go.rMd),
          borderSide: BorderSide(color: g.outline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Go.rMd),
          borderSide: BorderSide(color: g.primary, width: 1),
        ),
      ),
    );
  }
}

// =====================================================================
// 依次浮入容器（对齐 .go-stagger + go-glass-rise 动画）
// =====================================================================
class GoStagger extends StatefulWidget {
  final List<Widget> children;
  final double spacing;
  const GoStagger({super.key, required this.children, this.spacing = 0});
  @override
  State<GoStagger> createState() => _GoStaggerState();
}

class _GoStaggerState extends State<GoStagger> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final start = (i * 0.08).clamp(0.0, 0.5);
              final t = ((_c.value - start) / (1 - start)).clamp(0.0, 1.0);
              final e = Curves.easeOutCubic.transform(t);
              return Opacity(
                opacity: e,
                child: Transform.translate(offset: Offset(0, 13 * (1 - e)), child: child),
              );
            },
            child: Padding(padding: EdgeInsets.only(bottom: widget.spacing), child: widget.children[i]),
          ),
      ],
    );
  }
}

// =====================================================================
// 双环加载指示器（对齐 PolySpinner.vue）
// =====================================================================
class PolySpinner extends StatefulWidget {
  final double size; // dp
  const PolySpinner({super.key, this.size = 28});
  @override
  State<PolySpinner> createState() => _PolySpinnerState();
}

class _PolySpinnerState extends State<PolySpinner> with TickerProviderStateMixin {
  late final AnimationController _cw = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050))..repeat();
  late final AnimationController _ccw = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();

  @override
  void dispose() {
    _cw.dispose();
    _ccw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    // 两个环每帧旋转；用 RepaintBoundary 把重绘限制在这个小方块内。
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          children: [
            RotationTransition(
              turns: _cw,
              child: CustomPaint(size: Size.square(widget.size), painter: _RingPainter(color: g.primary, inset: 0, startQuarter: true)),
            ),
            RotationTransition(
              turns: ReverseAnimation(_ccw),
              child: CustomPaint(size: Size.square(widget.size), painter: _RingPainter(color: g.tertiary, inset: widget.size * 0.16, startQuarter: false)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  final double inset;
  final bool startQuarter;
  _RingPainter({required this.color, required this.inset, required this.startQuarter});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(inset);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    final start = startQuarter ? -math.pi / 2 : math.pi / 2;
    canvas.drawArc(r, start, math.pi / 2, false, paint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.color != color || old.inset != inset;
}
