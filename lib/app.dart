import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/theme/app_theme.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/update_controller.dart';
import 'package:toneup_read/widgets/bottom_nav.dart';
import 'package:toneup_read/widgets/go_update_sheet.dart';
import 'package:toneup_read/screens/home_screen.dart';
import 'package:toneup_read/screens/vocab_screen.dart';
import 'package:toneup_read/screens/sentence_screen.dart';
import 'package:toneup_read/screens/mine_screen.dart';
import 'package:toneup_read/screens/article_screen.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});
  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  // Tab 顺序对齐 BottomNav：首页 / 词汇 / 句子 / 我的
  static const _tabs = <Widget>[
    HomeScreen(),
    VocabScreen(),
    SentenceScreen(),
    MineScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final dark = ref.watch(themeModeProvider);
    final index = ref.watch(tabIndexProvider);
    return MaterialApp(
      title: '一潼上岸·阅读',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      // 更新观察者必须挂在 home 之下（Navigator 之内），弹更新面板才找得到 Navigator
      home: _UpdateReadyWatcher(
        child: Scaffold(
          body: GoBackdrop(child: IndexedStack(index: index, children: _tabs)),
          bottomNavigationBar: BottomNav(currentIndex: index, onTap: (i) => ref.read(tabIndexProvider.notifier).set(i)),
        ),
      ),
      routes: {
        '/article': (c) => const ArticleScreen(),
      },
    );
  }
}

/// 应用内更新的启动观察者：打开 App 即静默检查（每天一次），发现新版自动后台
/// 断点续传下载；包就绪后弹一次「立即安装」面板。测试环境 offline，全部空转。
class _UpdateReadyWatcher extends ConsumerStatefulWidget {
  final Widget child;
  const _UpdateReadyWatcher({required this.child});

  @override
  ConsumerState<_UpdateReadyWatcher> createState() => _UpdateReadyWatcherState();
}

class _UpdateReadyWatcherState extends ConsumerState<_UpdateReadyWatcher> {
  bool _prompted = false; // 每次启动最多提示一次，取消后靠「我的」入口行红点
  UpdateController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final c = ref.read(updateProvider);
      _controller = c;
      await c.init();
      if (!mounted) return;
      c.addListener(_promptIfNeeded);
      await c.autoCheck();
      _promptIfNeeded();
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_promptIfNeeded);
    super.dispose();
  }

  void _promptIfNeeded() {
    if (!mounted || _prompted) return;
    final c = ref.read(updateProvider);
    if (c.phase != UpdatePhase.ready) return;
    _prompted = true;
    showGoUpdateSheet(context, c);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
