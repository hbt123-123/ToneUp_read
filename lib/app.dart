import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/theme/app_theme.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/widgets/bottom_nav.dart';
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
      home: Scaffold(
        body: GoBackdrop(child: IndexedStack(index: index, children: _tabs)),
        bottomNavigationBar: BottomNav(currentIndex: index, onTap: (i) => ref.read(tabIndexProvider.notifier).set(i)),
      ),
      routes: {
        '/article': (c) => const ArticleScreen(),
      },
    );
  }
}
