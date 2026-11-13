import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:toneup_read/features/favorites/screens/review_screen.dart';
import 'package:toneup_read/features/favorites/widgets/sentence_card.dart';
import 'package:toneup_read/features/favorites/widgets/word_card.dart';
import 'package:toneup_read/features/favorites/widgets/word_occurrence_sheet.dart';
import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_icon.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 收藏（原「词汇」+「句子」合并）：轻量管理单词与句子收藏。
///
/// - 单词：全部/单词/短语筛选、出处回原文、删除、清空、导出（半角逗号分隔）。
/// - 句子：翻译/朗读/复制/回到原文/LLM 拆解。
/// - 复习不再是底部一级入口，只保留顶部「待复习」卡片作为二级入口。
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});
  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  static const _tabWords = 0;
  static const _tabSentences = 1;

  int _segment = _tabWords;
  List<Map<String, dynamic>> _heads = [];
  String _mode = 'all';
  int _dueCount = 0;
  Map<String, dynamic>? _occ;
  List<Map<String, dynamic>> _sentences = [];
  Timer? _reloadTimer;
  int _seenRev = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWords();
      _loadSentences();
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    super.dispose();
  }

  /// 收藏在别处被改动时刷新（防抖：连续点词/评分只重载一次）。
  void _onVocabChanged() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _loadWords();
      _loadSentences();
    });
  }

  List<Map<String, dynamic>> get _filtered =>
      _mode == 'all' ? _heads : _heads.where((h) => h['kind'] == _mode).toList();

  Future<void> _loadWords() async {
    try {
      final svc = ref.read(vocabProvider);
      await svc.syncHeadsFromCache();
      final heads = await svc.getHeads();
      final due = await svc.dueCount();
      if (!mounted) return;
      setState(() {
        _heads = heads;
        _dueCount = due;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收藏加载失败: $e')));
    }
  }

  Future<void> _loadSentences() async {
    try {
      final rawSent = await ref.read(vocabProvider).getSentences();
      final rows = rawSent.map((s) {
        dynamic analysis;
        try {
          if (s['analysis'] != null) analysis = jsonDecode(s['analysis'] as String);
        } catch (_) {}
        return {...s, '_analysis': analysis, '_analyzing': false, '_translating': false, '_trans': null, '_transErr': null};
      }).toList();
      if (!mounted) return;
      setState(() => _sentences = rows);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('句子加载失败: $e')));
    }
  }

  Future<void> _openOcc(Map<String, dynamic> h) async {
    final list = await ref.read(vocabProvider).getOccurrence(h['head'] as String);
    if (!mounted) return;
    setState(() => _occ = {'head': h['head'], 'zh': h['zh'] ?? '', 'list': list});
  }

  void _goArticle(Map<String, dynamic> o) {
    final guid = o['articleGuid'] as String?;
    if (guid == null || guid.isEmpty) return;
    setState(() => _occ = null);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArticleScreen(guid: guid, focusPara: (o['paraIndex'] as int?) ?? -1, focusTok: (o['tokIndex'] as int?) ?? -1),
      ),
    );
  }

  Future<void> _remove(Map<String, dynamic> h) async {
    final ok = await _confirm('删除', '从收藏里移除「${h['head']}」？');
    if (ok != true) return;
    await ref.read(vocabProvider).removeHead(h['head'] as String);
    if (!mounted) return;
    setState(() {
      _heads = _heads.where((x) => x['head'] != h['head']).toList();
    });
    _dueCount = await ref.read(vocabProvider).dueCount();
    if (mounted) setState(() {});
  }

  Future<void> _clearAll() async {
    final ok = await _confirm('清空词汇', '确定删除全部收藏词汇与复习进度？');
    if (ok != true) return;
    await ref.read(vocabProvider).clearVocab();
    if (!mounted) return;
    setState(() {
      _heads = [];
      _dueCount = 0;
    });
  }

  Future<bool?> _confirm(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
  }

  // ===================== 句子动作 =====================

  Future<void> _onTranslate(Map<String, dynamic> s) async {
    final text = '${s['sentence'] ?? ''}';
    if (text.trim().isEmpty) return;
    setState(() {
      s['_translating'] = true;
      s['_trans'] = null;
      s['_transErr'] = null;
    });
    try {
      final out = await ref.read(translateProvider).translate(text, from: 'en', to: 'zh');
      if (!mounted) return;
      setState(() {
        s['_translating'] = false;
        s['_trans'] = out;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        s['_translating'] = false;
        s['_transErr'] = errText(e);
      });
    }
  }

  void _onSpeak(Map<String, dynamic> s) {
    final text = '${s['sentence'] ?? ''}';
    if (text.trim().isEmpty) return;
    ref.read(ttsProvider).speak(text);
  }

  Future<void> _copy(String text, String tip) async {
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack(tip);
  }

  void _goArticleFromSentence(Map<String, dynamic> s) {
    final guid = s['articleGuid'] as String?;
    if (guid == null || guid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArticleScreen(guid: guid, focusPara: (s['paraIndex'] as int?) ?? -1, focusTok: (s['tokIndex'] as int?) ?? -1),
      ),
    );
  }

  Future<void> _onAnalyze(Map<String, dynamic> s) async {
    if (s['sentence'] == null) return;
    setState(() => s['_analyzing'] = true);
    try {
      final data = await ref.read(vocabProvider).analyzeSentence(s['sentence'] as String);
      if (!mounted) return;
      setState(() => s['_analysis'] = data);
    } catch (e) {
      if (!mounted) return;
      final msg = errText(e);
      _snack(msg.length > 60 ? msg.substring(0, 60) : msg);
    } finally {
      if (mounted) setState(() => s['_analyzing'] = false);
    }
  }

  // ===================== 生词导出 =====================

  /// 导出文本：只含英文 head，**半角逗号 + 半角空格**拼接（接收方按此解析，禁用全角逗号）。
  String get _exportText => _heads.map((h) => '${h['head']}').join(', ');

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _copyExport() async {
    final txt = _exportText;
    if (txt.isEmpty) {
      _snack('暂无生词可导出');
      return;
    }
    await Clipboard.setData(ClipboardData(text: txt));
    _snack('已复制 ${_heads.length} 个词');
  }

  Future<void> _shareExport() async {
    final txt = _exportText;
    if (txt.isEmpty) {
      _snack('暂无生词可导出');
      return;
    }
    await SharePlus.instance.share(ShareParams(text: txt, subject: '生词表'));
  }

  void _openExportSheet() {
    if (_heads.isEmpty) {
      _snack('暂无生词可导出');
      return;
    }
    final g = GoPalette.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (c) => Container(
        decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
        padding: EdgeInsets.only(left: Go.sp5, right: Go.sp5, top: Go.sp4, bottom: MediaQuery.of(c).padding.bottom + Go.sp6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: Go.r(64), height: 3, decoration: BoxDecoration(color: g.outlineStrong, borderRadius: BorderRadius.circular(Go.rFull))),
            const SizedBox(height: Go.sp4),
            Text('导出生词', style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: g.onSurface)),
            const SizedBox(height: Go.sp2),
            Text('${_heads.length} 个词，英文词条以半角逗号分隔', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
            const SizedBox(height: Go.sp5),
            _exportBtn(g, label: '复制文本', icon: 'copy', filled: true, onTap: () {
              Navigator.pop(c);
              _copyExport();
            }),
            const SizedBox(height: Go.sp3),
            _exportBtn(g, label: '分享到单词应用', icon: 'export', filled: false, onTap: () {
              Navigator.pop(c);
              _shareExport();
            }),
          ],
        ),
      ),
    );
  }

  Widget _exportBtn(GoPalette g, {required String label, required String icon, required bool filled, required VoidCallback onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? g.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(Go.rFull),
            border: filled ? null : Border.all(color: g.primary, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GoIcon(icon, size: Go.r(40), color: filled ? g.onPrimary : g.primary),
              const SizedBox(width: Go.sp2),
              Text(label, style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: filled ? g.onPrimary : g.primary)),
            ],
          ),
        ),
      );

  // ===================== 视图 =====================

  @override
  Widget build(BuildContext context) {
    final onThisTab = ref.watch(tabIndexProvider) == 1;
    // 只有本页可见时才响应收藏变更：阅读中每点一个词都会 bump，
    // 隐藏的 Tab 若跟着全量重载（含 vocab_occ 聚合）会拖慢阅读。
    if (onThisTab) {
      ref.listen(vocabRevisionProvider, (_, _) {
        _seenRev = ref.read(vocabRevisionProvider);
        _onVocabChanged();
      });
      // 切回本页时若期间有变更，补一次刷新，避免看到旧数据。
      final rev = ref.read(vocabRevisionProvider);
      if (rev != _seenRev) {
        _seenRev = rev;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onVocabChanged();
        });
      }
    }
    final empty = _segment == _tabWords ? _filtered.isEmpty : _sentences.isEmpty;
    return GoPage(
      topPad: false,
      globe: true,
      globeActive: onThisTab && empty,
      child: Stack(
        children: [
          Column(
            children: [
              _appbar(),
              _segmentBar(),
              Expanded(child: _segment == _tabWords ? _wordsScroll() : _sentencesScroll()),
            ],
          ),
          if (_occ != null)
            WordOccurrenceOverlay(
              head: '${_occ!['head']}',
              zh: '${_occ!['zh'] ?? ''}',
              list: _occ!['list'] as List,
              onClose: () => setState(() => _occ = null),
              onOpenArticle: _goArticle,
            ),
        ],
      ),
    );
  }

  Widget _appbar() => GoAppBar(
        title: '收藏',
        style: GoAppBarStyle.floating,
        actions: [
          if (_segment == _tabWords && _heads.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: Go.sp3),
              child: GestureDetector(
                onTap: _clearAll,
                child: Text('清空', style: TextStyle(fontSize: Go.fsMeta, color: GoPalette.of(context).onSurface3)),
              ),
            ),
          if (_segment == _tabWords)
            Padding(
              padding: const EdgeInsets.only(left: Go.sp2),
              child: GoIconBtn(icon: 'export', onTap: _openExportSheet),
            ),
        ],
      );

  /// 单词 / 句子 分段切换（收藏的两类内容）。
  Widget _segmentBar() {
    final g = GoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp2, Go.sp6, Go.sp3),
      child: Row(
        children: [
          for (final item in [
            (_tabWords, '单词 ${_heads.length}'),
            (_tabSentences, '句子 ${_sentences.length}'),
          ]) ...[
            GestureDetector(
              onTap: () => setState(() => _segment = item.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp2),
                decoration: BoxDecoration(
                  color: _segment == item.$1 ? g.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(Go.rFull),
                  border: Border.all(color: _segment == item.$1 ? g.primary : g.outline, width: 0.5),
                ),
                child: Text(
                  item.$2,
                  style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: _segment == item.$1 ? g.onPrimary : g.onSurface3),
                ),
              ),
            ),
            const SizedBox(width: Go.sp2),
          ],
        ],
      ),
    );
  }

  /// 词卡量大（可达数千），用 SliverList 懒构建；早先把全部词卡塞进 Column，
  /// 进页面一次性构建三万个 Widget，首屏直接卡住。
  Widget _wordsScroll() {
    final items = _filtered;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _dueCard()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, 0, Go.sp6, Go.sp2),
            child: Text('${_heads.length} 个词族', style: TextStyle(fontSize: Go.fsMeta, color: GoPalette.of(context).onSurface3)),
          ),
        ),
        SliverToBoxAdapter(child: _modeTabs()),
        if (items.isEmpty)
          const SliverToBoxAdapter(
            child: GoEmpty(icon: 'book', title: '还没有收藏的词汇', desc: '在正文里点词即可沉淀到这里'),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp6),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => FavoriteWordCard(
                head: items[i],
                onTap: () => _openOcc(items[i]),
                onRemove: () => _remove(items[i]),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: Go.sp16)),
      ],
    );
  }

  Widget _dueCard() {
    final g = GoPalette.of(context);
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReviewScreen())),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp4),
        padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp5),
        decoration: BoxDecoration(color: g.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Go.rLg), boxShadow: g.elev1),
        child: Row(
          children: [
            Text('$_dueCount', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: g.primary)),
            Padding(padding: const EdgeInsets.only(left: Go.sp2), child: Text('张待复习', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface))),
            const Spacer(),
            Text('去复习 ›', style: TextStyle(fontSize: Go.fsBodySm, color: g.primary, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _modeTabs() {
    final g = GoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Go.sp6, 0, Go.sp6, Go.sp3),
      child: Row(
        children: [
          for (final m in [('all', '全部'), ('word', '单词'), ('phrase', '短语')]) ...[
            GestureDetector(
              onTap: () => setState(() => _mode = m.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
                decoration: BoxDecoration(
                  color: _mode == m.$1 ? g.primary95 : Colors.transparent,
                  borderRadius: BorderRadius.circular(Go.rFull),
                  border: Border.all(color: _mode == m.$1 ? g.primary : g.outline, width: 0.5),
                ),
                child: Text(m.$2, style: TextStyle(fontSize: Go.fsMeta, color: _mode == m.$1 ? g.primary : g.onSurface3)),
              ),
            ),
            const SizedBox(width: Go.sp2),
          ],
        ],
      ),
    );
  }

  /// 收藏句子最多 200 条（getSentences 内 LIMIT），直接单列铺开即可。
  Widget _sentencesScroll() {
    if (_sentences.isEmpty) {
      return const GoEmpty(icon: 'reading', title: '还没有收藏的句子', desc: '在正文里点词，原句会自动沉淀到这里');
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp2, Go.sp6, Go.sp2),
            child: Text('${_sentences.length} 个收藏句子', style: TextStyle(fontSize: Go.fsMeta, color: GoPalette.of(context).onSurface3)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp2, Go.sp6, Go.sp8),
            child: Column(
              children: [
                for (final s in _sentences)
                  FavoriteSentenceCard(
                    sentence: s,
                    onTranslate: () => _onTranslate(s),
                    onSpeak: () => _onSpeak(s),
                    onCopy: () => _copy('${s['sentence'] ?? ''}', '已复制句子'),
                    onOpenArticle: () => _goArticleFromSentence(s),
                    onAnalyze: () => _onAnalyze(s),
                    onCopyTranslation: (t) => _copy(t, '已复制译文'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Go.sp16),
        ],
      ),
    );
  }
}
