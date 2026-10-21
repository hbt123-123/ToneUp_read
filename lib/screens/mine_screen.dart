import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/services/update_controller.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_icon.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:toneup_read/widgets/go_update_sheet.dart';

class MineScreen extends ConsumerStatefulWidget {
  const MineScreen({super.key});
  @override
  ConsumerState<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends ConsumerState<MineScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeUpdatePrompt();
    });
  }

  // —— 应用内更新 ——

  /// 入口行副标题：把状态机翻译成一句人话。
  String _updateSub(UpdateController c) => switch (c.phase) {
        UpdatePhase.checking => '正在检查…',
        UpdatePhase.available => '发现 v${c.info?.version ?? ''}',
        UpdatePhase.latest => '已是最新版本',
        UpdatePhase.failed => c.error ?? '检查失败',
        UpdatePhase.downloading => c.total > 0 ? '后台下载中 ${(c.progress * 100).toStringAsFixed(0)}%' : '后台下载中…',
        UpdatePhase.verifying => '正在校验…',
        UpdatePhase.ready => '已就绪，点击安装',
        UpdatePhase.installing => '等待安装确认',
        _ => c.installedLabel.isEmpty ? '当前版本' : '当前 ${c.installedLabel}',
      };

  DateTime? _lastManualCheck;

  Future<void> _checkUpdate() async {
    final now = DateTime.now();
    if (_lastManualCheck != null && now.difference(_lastManualCheck!) < const Duration(seconds: 30)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('刚检查过，稍等一会儿再试')));
      return;
    }
    _lastManualCheck = now;
    final c = ref.read(updateProvider);
    await c.checkNow();
    if (!mounted) return;
    switch (c.phase) {
      case UpdatePhase.latest:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已是最新版本')));
      case UpdatePhase.failed:
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? '检查失败')));
      case UpdatePhase.available:
      case UpdatePhase.ready:
      case UpdatePhase.downloading:
        await showGoUpdateSheet(context, c);
      default:
        break;
    }
  }

  /// 启动时静默检查（每天最多一次）；同一版本只弹一次卡片，之后只留红点。
  Future<void> _maybeUpdatePrompt() async {
    final c = ref.read(updateProvider);
    await c.init();
    await c.autoCheck();
    if (!mounted) return;
    if (await c.shouldPrompt() && mounted) {
      await showGoUpdateSheet(context, c);
    }
  }

  Future<bool?> _confirm(String title, String content, {String confirmText = '确定'}) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(confirmText)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(updateProvider);

    return GoPage(
      topPad: false,
      child: Column(
        children: [
          const GoAppBar(title: '我的', style: GoAppBarStyle.floating),
          Expanded(
            child: SingleChildScrollView(
              child: GoContent(
                child: GoStagger(
                  spacing: Go.sp8,
                  children: [
                    // —— 数据管理 ——
                    GoSection(
                      title: '数据管理',
                      children: [
                        GoCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              _navRow(
                                icon: 'trash',
                                title: '清除缓存',
                                sub: '清空已缓存的文章与词典，保留词汇与句子',
                                onTap: () async {
                                  final ok = await _confirm('清除缓存', '将清空已缓存的文章与词典，词汇与句子不受影响。');
                                  if (ok == true) await ref.read(dbProvider).clearCache();
                                  if (mounted) setState(() {});
                                },
                              ),
                              _navRow(
                                icon: 'alert',
                                title: '清空全部数据',
                                sub: '删除文章、词汇与句子',
                                danger: true,
                                onTap: () async {
                                  final ok = await _confirm(
                                    '清空全部数据',
                                    '将删除文章、词汇与句子，且不可恢复。',
                                    confirmText: '清空',
                                  );
                                  if (ok == true) await ref.read(dbProvider).clearAll();
                                  if (mounted) setState(() {});
                                },
                                divider: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    // —— 关于 ——
                    GoSection(
                      title: '关于',
                      children: [
                        GoCard(
                          padding: EdgeInsets.zero,
                          child: _navRow(
                            icon: 'refresh',
                            title: '检查更新',
                            sub: _updateSub(update),
                            onTap: _checkUpdate,
                            spin: update.phase == UpdatePhase.checking,
                            dot: update.phase == UpdatePhase.available || update.phase == UpdatePhase.ready,
                            highlight: update.phase == UpdatePhase.available || update.phase == UpdatePhase.ready,
                            divider: false,
                          ),
                        ),
                      ],
                    ),

                    Padding(
                      padding: const EdgeInsets.only(top: Go.sp8),
                      child: Column(
                        children: [
                          const Text(
                            '一潼上岸·阅读 · By 潼潼',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: Go.fsCap, color: Go.onSurfaceDisabled, letterSpacing: 0.5),
                          ),
                          const SizedBox(height: Go.sp1),
                          Text(update.installedLabel, textAlign: TextAlign.center, style: const TextStyle(fontSize: Go.fsCap, color: Go.onSurfaceDisabled)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navRow({
    required String icon,
    required String title,
    String? sub,
    VoidCallback? onTap,
    bool danger = false,
    bool divider = true,
    bool highlight = false,
    bool dot = false,
    bool spin = false,
  }) {
    return Column(
      children: [
        if (divider) const Divider(height: 0.5, thickness: 0.5, color: Go.outline),
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp3),
            child: Row(
              children: [
                Container(
                  width: Go.r(64),
                  height: Go.r(64),
                  decoration: BoxDecoration(color: danger ? Go.danger.withValues(alpha: 0.14) : Go.primary95, borderRadius: BorderRadius.circular(Go.rSm)),
                  child: Center(child: GoIcon(icon, size: Go.r(48), color: danger ? Go.danger : Go.primary, spin: spin)),
                ),
                const SizedBox(width: Go.sp4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w500, color: danger ? Go.error : Go.onSurface)),
                      if (sub != null) ...[
                        const SizedBox(height: 1),
                        Text(sub, style: TextStyle(fontSize: Go.fsMeta, color: highlight ? Go.primary : Go.onSurface3)),
                      ],
                    ],
                  ),
                ),
                if (dot)
                  Container(
                    width: Go.sp4,
                    height: Go.sp4,
                    margin: const EdgeInsets.only(right: Go.sp2),
                    decoration: const BoxDecoration(color: Go.primary, shape: BoxShape.circle),
                  ),
                const Icon(Icons.chevron_right, size: 18, color: Go.onSurfaceDisabled),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
