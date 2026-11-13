import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/favorites/screens/vocab_organize_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/update_controller.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:toneup_read/widgets/go_update_sheet.dart';

/// 「我的」：只保留 外观 / 数据管理 / 关于 三段，设置项不再堆入口。
class MineScreen extends ConsumerStatefulWidget {
  const MineScreen({super.key});
  @override
  ConsumerState<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends ConsumerState<MineScreen> {
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
    final dark = ref.watch(themeModeProvider);
    final g = GoPalette.of(context);

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
                    // —— 外观 ——
                    GoSection(
                      title: '外观',
                      children: [
                        GoCard(
                          padding: EdgeInsets.zero,
                          child: GoListTile(
                            icon: dark ? 'moon' : 'sun',
                            title: '深色模式',
                            subtitle: dark ? '当前：深色' : '当前：浅色',
                            divider: false,
                            trailing: GoSwitch(
                              value: dark,
                              onChanged: (v) => ref.read(themeModeProvider.notifier).set(v),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // —— 学习工具 ——
                    GoSection(
                      title: '学习工具',
                      children: [
                        GoCard(
                          padding: EdgeInsets.zero,
                          child: GoListTile(
                            icon: 'robot',
                            title: 'AI 整理收藏',
                            subtitle: '按主题归类已收藏的单词，并补全释义与例句',
                            divider: false,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const VocabOrganizeScreen()),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // —— 数据管理 ——
                    GoSection(
                      title: '数据管理',
                      children: [
                        GoCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              GoListTile(
                                icon: 'trash',
                                title: '清除缓存',
                                subtitle: '清空已缓存的文章与词典，保留收藏',
                                onTap: () async {
                                  final ok = await _confirm('清除缓存', '将清空已缓存的文章与词典，收藏的单词与句子不受影响。');
                                  if (ok == true) await ref.read(dbProvider).clearCache();
                                  if (mounted) setState(() {});
                                },
                              ),
                              GoListTile(
                                icon: 'alert',
                                title: '清空全部数据',
                                subtitle: '删除文章、单词与句子',
                                danger: true,
                                onTap: () async {
                                  final ok = await _confirm(
                                    '清空全部数据',
                                    '将删除文章、单词与句子，且不可恢复。',
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
                          child: GoListTile(
                            icon: 'refresh',
                            title: '检查更新',
                            subtitle: _updateSub(update),
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
                          Text(
                            '一潼上岸·阅读 · By 潼潼',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: Go.fsCap, color: g.onSurfaceDisabled, letterSpacing: 0.5),
                          ),
                          const SizedBox(height: Go.sp1),
                          Text(update.installedLabel, textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsCap, color: g.onSurfaceDisabled)),
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
}
