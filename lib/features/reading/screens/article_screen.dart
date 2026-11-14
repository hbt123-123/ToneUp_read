import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/reading/controllers/reading_controller.dart';
import 'package:toneup_read/features/reading/models/reading_state.dart';
import 'package:toneup_read/features/reading/widgets/article_summary_sheet.dart';
import 'package:toneup_read/features/reading/widgets/reading_app_bar.dart';
import 'package:toneup_read/features/reading/widgets/reading_content.dart';
import 'package:toneup_read/features/reading/widgets/reading_settings_sheet.dart';
import 'package:toneup_read/features/reading/widgets/reading_toolbar.dart';
import 'package:toneup_read/features/reading/widgets/sentence_action_sheet.dart';
import 'package:toneup_read/features/reading/widgets/word_popover.dart';
import 'package:toneup_read/features/reading/widgets/word_popup.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/tts_voices.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// 阅读器页面：只做「组合」——数据/选区/朗读在 [ReadingController]，
/// 顶栏、正文、设置、操作条、词卡、翻译弹层各自独立成 widget。
class ArticleScreen extends ConsumerStatefulWidget {
  final int? articleId;
  final String? guid;
  final String? title;
  final int focusPara;
  final int focusTok;
  const ArticleScreen({super.key, this.articleId, this.guid, this.title, this.focusPara = -1, this.focusTok = -1});

  /// 选区文本 → 查询文本。
  /// 单个词：削掉单词周围的标点（`word,` → `word`）；
  /// 整句 / 多词：**原样保留**，不能像以前那样把空格也一起删掉（否则词与词会黏成一串）。
  @visibleForTesting
  static String cleanQueryText(String text) {
    final t = text.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty || t.contains(' ')) return t;
    return t.replaceAll(RegExp(r"[^A-Za-z'’\-]"), '').trim();
  }

  @override
  ConsumerState<ArticleScreen> createState() => _ArticleScreenState();
}

class _ArticleScreenState extends ConsumerState<ArticleScreen> {
  late final ReadingController _c;
  bool _showSettings = false;

  /// 点词「就地浮窗」的锚定上下文：查询文本 + 收藏上下文 + 词的屏幕包围盒。
  /// 滚动正文 / 点 × / 再点同一个词时清空。
  _WordPop? _pop;

  @override
  void initState() {
    super.initState();
    _c = ReadingController(
      ref: ref,
      articleId: widget.articleId,
      guid: widget.guid,
      title: widget.title,
      focusPara: widget.focusPara,
      focusTok: widget.focusTok,
      onMessage: _snack,
    );
    // 浮窗锚定的是瞬时屏幕坐标，正文一滚就失效——滚动即收起（防抖没必要，收起是幂等 setState）。
    _c.scrollController.addListener(_onScrollClosePop);
  }

  @override
  void dispose() {
    _c.scrollController.removeListener(_onScrollClosePop);
    _c.dispose();
    super.dispose();
  }

  void _onScrollClosePop() {
    if (_pop != null) setState(() => _pop = null);
  }

  void _closePop() {
    if (_pop == null) return;
    setState(() => _pop = null);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ================= 设置 =================

  Future<void> _changeFont(int d) async {
    final cur = ref.read(appConfigProvider).fontSize;
    final v = (cur + d).clamp(14, 28).toDouble();
    await ref.read(appConfigProvider).setReader(fontSize: v);
  }

  Future<void> _changeLine(double d) async {
    final cur = ref.read(appConfigProvider).lineHeight;
    final v = ((cur + d) * 10).round() / 10;
    await ref.read(appConfigProvider).setReader(lineHeight: v.clamp(1.2, 2.4));
  }

  Future<void> _changeFontFamily(String f) async {
    await ref.read(appConfigProvider).setReader(font: f);
  }

  Future<void> _changePara(double d) async {
    final cur = ref.read(appConfigProvider).paraSpacing;
    await ref.read(appConfigProvider).setReader(paraSpacing: (cur + d).clamp(10.0, 32.0));
  }

  /// Edge 音色 → 中文标签（顺序即展示顺序，见 kEdgeVoices）。
  static String _voiceLabel(String id) {
    for (final v in kEdgeVoices) {
      if (v[0] == id) return v[1];
    }
    return id;
  }

  Future<void> _openVoiceSheet() async {
    // 试听会顶掉正在进行的全文朗读：先停掉阅读器侧状态，避免胶囊和高亮残留。
    if (_c.ttsPlaying || _c.ttsSynthesizing) {
      await _c.toggleReadAloud();
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ReadingVoiceSheet(),
    );
  }

  // ================= 点词 / 选区 =================

  /// 沉浸模式开关：点正文空白处切换顶栏显隐；隐藏时顺手收掉设置面板。
  void _toggleChrome() {
    _c.toggleChrome();
    if (!_c.chromeVisible && _showSettings) setState(() => _showSettings = false);
  }

  void _onToken(ReadingToken tk, bool isLong, String ctx, int pi, int ti, Rect? rect, {bool isTitle = false}) {
    if (!tk.word) return;
    if (_c.selectMode) {
      _c.toggleSelToken(pi, ti);
      return;
    }
    final sentence = isTitle ? _c.state.title.trim() : _c.sentenceAround(ctx, ti);
    if (isLong) {
      _closePop(); // 选区条与浮窗不共存
      if (sentence.isNotEmpty) {
        _c.setSelectionText(sentence, isTitle ? -1 : pi, isTitle ? -1 : ti);
      }
      return;
    }
    ref
        .read(vocabProvider)
        .recordOccurrence(tk.text, sentence, _c.state.guid, _c.state.title, _c.state.sourceHost, pi, ti)
        .catchError((_) {});
    ref.read(vocabRevisionProvider.notifier).bump();
    final clean = ArticleScreen.cleanQueryText(tk.text);
    if (clean.isEmpty) return;
    // 同一个词再点一下 = 收起浮窗；不同词则重新锚定（不再走整屏底部弹层）。
    if (_pop != null && _pop!.pi == pi && _pop!.ti == ti) {
      _closePop();
      return;
    }
    if (rect != null) {
      setState(() => _pop = _WordPop(clean, sentence, pi, ti, rect));
    } else {
      // 命中盒拿不到（极端布局）：退回完整词卡弹层，保底可用。
      _openWord(clean, sentence: sentence, paraIndex: pi, tokIndex: ti);
    }
  }

  /// 浮窗「详情」→ 完整词卡（词形/标签/词频/建议词/中英切换），收起浮窗再开弹层。
  void _openPopDetail() {
    final pop = _pop;
    if (pop == null) return;
    _closePop();
    _openWord(pop.query, sentence: pop.sentence, paraIndex: pop.pi, tokIndex: pop.ti);
  }

  void _openWord(String text, {String sentence = '', int paraIndex = -1, int tokIndex = -1}) {
    final clean = ArticleScreen.cleanQueryText(text);
    if (clean.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => WordCardSheet(
        word: clean,
        sentence: sentence.isNotEmpty ? sentence : clean,
        articleGuid: _c.state.guid,
        articleTitle: _c.state.title,
        sourceLabel: _c.state.sourceHost,
        paraIndex: paraIndex,
        tokIndex: tokIndex,
        onClose: () => Navigator.pop(c),
        onSpeak: (w) => _c.speakPreview(w),
      ),
    );
  }

  Future<void> _saveSentence() async {
    final text = _c.effectiveSelection;
    if (text.trim().isEmpty) return;
    final a = _c.selAnchor();
    try {
      await ref.read(vocabProvider).saveSentence(text, _c.state.guid, _c.state.title, _c.state.sourceHost, a.pi, a.ti);
      ref.read(vocabRevisionProvider.notifier).bump();
      if (!mounted) return;
      _snack('已收藏句子');
      _c.clearSelection();
    } catch (e) {
      _snack('收藏失败: $e');
    }
  }

  /// 划词「查询」：先记一次出现（单词与短语同一路径），再开词卡。
  Future<void> _querySelection() async {
    final text = _c.effectiveSelection;
    if (text.trim().isEmpty) return;
    final clean = ArticleScreen.cleanQueryText(text);
    final a = _c.selAnchor();
    final sentence = _c.selSentence(text);
    _c.clearSelection();
    if (clean.isEmpty) return;
    try {
      await ref.read(vocabProvider).recordOccurrence(clean, sentence, _c.state.guid, _c.state.title, _c.state.sourceHost, a.pi, a.ti);
      ref.read(vocabRevisionProvider.notifier).bump();
    } catch (_) {
      // 入库失败不阻断查词（本地写入，极少发生）。
    }
    if (!mounted) return;
    _openWord(text, sentence: sentence, paraIndex: a.pi, tokIndex: a.ti);
  }

  /// 划词「翻译」：打开句子面板（翻译页签；AI 分析页签里的收藏/回跳需要这里的锚点）。
  void _translateSelection() {
    final text = _c.effectiveSelection;
    if (text.trim().isEmpty) return;
    final a = _c.selAnchor();
    _c.clearSelection();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => SentenceActionSheet(
        text: text,
        articleGuid: _c.state.guid,
        articleTitle: _c.state.title,
        sourceLabel: _c.state.sourceHost,
        paraIndex: a.pi,
        tokIndex: a.ti,
        onClose: () => Navigator.pop(c),
      ),
    );
  }

  // ================= AI（精选 / 总结） =================

  /// sparkle = AI 菜单：总结全文 + AI 精选（未精选时直接开精选入口）。
  Future<void> _onAiTap() async {
    final st = _c.state;
    if (_c.curating || _c.summarizing) return;
    final hasCurated = st.curatedBlocks != null;
    final idx = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasCurated)
              Padding(
                padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp4, Go.sp5, Go.sp2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_c.curateSummary(st.blocks, st.curatedBlocks!), style: TextStyle(fontSize: Go.fsMeta, color: GoPalette.of(c).onSurface3)),
                ),
              ),
            ListTile(title: const Text('总结全文'), onTap: () => Navigator.pop(c, 3)),
            if (!hasCurated)
              ListTile(title: const Text('AI 精选本文'), onTap: () => Navigator.pop(c, 1))
            else ...[
              ListTile(title: Text(st.useCurated ? '切换到原文' : '切换到 AI 精选版'), onTap: () => Navigator.pop(c, 0)),
              ListTile(title: const Text('重新精选'), onTap: () => Navigator.pop(c, 1)),
              ListTile(title: const Text('删除精选版（还原原文）'), onTap: () => Navigator.pop(c, 2)),
            ],
          ],
        ),
      ),
    );
    if (idx == 3) {
      _openSummarySheet();
    } else if (idx == 0) {
      _c.toggleCurated();
    } else if (idx == 1) {
      await _runCurate();
    } else if (idx == 2) {
      await _c.removeCurated();
    }
  }

  void _openSummarySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => ArticleSummarySheet(controller: _c, onClose: () => Navigator.pop(c)),
    );
  }

  Future<void> _runCurate() async {
    try {
      final summary = await _c.runCurate();
      if (!mounted) return;
      if (summary == null) {
        _snack('AI 精选无可用正文，已还原原文');
        return;
      }
      if (summary.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary), duration: const Duration(seconds: 5)));
      }
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('AI 精选失败'),
          content: Text(errText(e)),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('确定'))],
        ),
      );
    }
  }

  Future<void> _openOriginal() async {
    final uri = Uri.tryParse(_c.state.sourceUrl.trim());
    if (uri == null || !uri.hasScheme) {
      _snack('原文链接无效');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack('无法打开原文，请稍后重试');
    } catch (_) {
      if (mounted) _snack('打开原文失败，请稍后重试');
    }
  }

  // ================= 视图 =================

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    final pal = GoReader.of(cfg.readerTheme);
    // 状态栏图标：夜读配浅色、纸色配深色（AnnotatedRegion 只作用于本页）。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: pal.isNight ? Brightness.light : Brightness.dark,
        statusBarBrightness: pal.isNight ? Brightness.dark : Brightness.light,
      ),
      child: GoPage(
        surface: pal.bg,
        topPad: false,
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => Stack(
            children: [
              Column(
                children: [
                  // 沉浸模式：点正文空白处收起顶栏/设置面板（AnimatedSize 平滑折叠，再点恢复）。
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _c.chromeVisible
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ReadingAppBar(
                                title: _c.state.title,
                                pal: pal,
                                selectMode: _c.selectMode,
                                ttsBusy: _c.ttsPlaying || _c.ttsSynthesizing,
                                useCurated: _c.state.useCurated,
                                settingsOpen: _showSettings,
                                onToggleSelect: _c.toggleSelectMode,
                                onToggleTts: _c.toggleReadAloud,
                                onAi: _onAiTap,
                                onToggleSettings: () => setState(() => _showSettings = !_showSettings),
                              ),
                              if (_c.selectMode)
                                Container(
                                  margin: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
                                  padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp3),
                                  decoration: BoxDecoration(
                                    color: pal.surface,
                                    borderRadius: BorderRadius.circular(Go.rMd),
                                    border: Border.all(color: pal.accent.withValues(alpha: 0.45), width: 0.8),
                                  ),
                                  child: Text('点选多个单词组成选区，点「查询」出词卡 · 点「翻译」看译文 · 再次点词取消选中',
                                      textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsMeta, height: Go.lhSnug, color: pal.secondary)),
                                ),
                              if (_showSettings)
                                ReadingSettingsPanel(
                                  cfg: cfg,
                                  pal: pal,
                                  onTheme: (t) => ref.read(appConfigProvider).setReader(theme: t),
                                  onFontStep: _changeFont,
                                  onLineStep: _changeLine,
                                  onFontFamily: _changeFontFamily,
                                  onParaStep: _changePara,
                                  onOpenVoice: _openVoiceSheet,
                                  voiceLabel: _voiceLabel(cfg.ttsVoice),
                                ),
                            ],
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  Expanded(child: _body(cfg, pal)),
                ],
              ),
              // 点词就地浮窗：锚定在词旁；选区条/朗读胶囊是活动 UI，压在其上。
              if (_pop != null) _popLayer(pal),
              ValueListenableBuilder<int>(
                valueListenable: _c.selVer,
                builder: (_, _, _) {
                  final text = _c.effectiveSelection;
                  if (text.isEmpty) return const SizedBox.shrink();
                  return ReadingSelectionBar(
                    pal: pal,
                    text: text,
                    onRead: _c.readSelection,
                    onQuery: _querySelection,
                    onTranslate: _translateSelection,
                    onSave: _saveSentence,
                    onCancel: _c.clearSelection,
                  );
                },
              ),
              if (_c.ttsSynthesizing || (_c.ttsPlaying && _c.ttsArticle))
                ReadingTtsPill(
                  pal: pal,
                  synthesizing: _c.ttsSynthesizing,
                  segVer: _c.ttsSegVer,
                  totalSegs: _c.segs.length,
                  onStop: _c.toggleReadAloud,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 浮窗定位：水平以词中心对齐并 clamp 到屏内；垂直方向「上方优先」——
  /// 词上方有 ≥260dp（或比下方更多空间）时贴词顶上方，否则翻到词底下方。
  /// 上方用 bottom 锚定向上生长，无需预知浮窗实际高度。
  Widget _popLayer(GoReaderPalette pal) {
    final pop = _pop!;
    final mq = MediaQuery.of(context);
    final screenW = mq.size.width;
    final screenH = mq.size.height;
    final popW = (screenW - Go.sp8 * 2).clamp(200.0, 320.0);
    final left = (pop.rect.center.dx - popW / 2).clamp(Go.sp4, screenW - popW - Go.sp4).toDouble();
    final spaceAbove = pop.rect.top - mq.padding.top;
    final spaceBelow = screenH - mq.padding.bottom - pop.rect.bottom;
    final above = spaceAbove >= 260 || spaceAbove > spaceBelow;
    Widget sheet({required double maxHeight, double? top, double? bottom}) => Positioned(
          left: left,
          top: top,
          bottom: bottom,
          child: WordPopover(
            // key 必须带上查询上下文：换词直接重开浮窗时 widget 位置不变，
            // 无 key 会复用旧 State 导致显示上一个词的释义。
            key: ValueKey('wordpop:${pop.pi}:${pop.ti}:${pop.query}'),
            word: pop.query,
            pal: pal,
            sentence: pop.sentence,
            articleGuid: _c.state.guid,
            articleTitle: _c.state.title,
            sourceLabel: _c.state.sourceHost,
            paraIndex: pop.pi,
            tokIndex: pop.ti,
            maxHeight: maxHeight,
            onClose: _closePop,
            onDetail: _openPopDetail,
            onSpeak: (w) => _c.speakPreview(w),
          ),
        );
    if (above) {
      return sheet(bottom: screenH - pop.rect.top + Go.sp2, maxHeight: (spaceAbove - Go.sp8).clamp(120.0, 280.0));
    }
    return sheet(top: pop.rect.bottom + Go.sp2, maxHeight: (spaceBelow - Go.sp8).clamp(120.0, 280.0));
  }

  Widget _body(AppConfigService cfg, GoReaderPalette pal) {
    if (_c.loading) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const PolySpinner(),
        const SizedBox(height: Go.sp6),
        Text('正文加载中…', style: TextStyle(color: pal.secondary, fontSize: Go.fsBodySm)),
      ]));
    }
    if (_c.error.isNotEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_c.error, style: TextStyle(color: pal.danger)),
          const SizedBox(height: Go.sp3),
          GestureDetector(onTap: _c.load, child: Text('重试', style: TextStyle(color: pal.accent, fontWeight: FontWeight.w600))),
        ]),
      );
    }
    // 正文未缓存（云端只缓存了元信息）：给占位块 + 打开原文。
    if (_c.state.plain.trim().isEmpty) return _noBody(cfg, pal);
    return ReadingContent(
      controller: _c,
      pal: pal,
      fontSize: cfg.fontSize,
      lineHeight: cfg.lineHeight,
      fontFamily: cfg.readerFont,
      paraSpacing: cfg.paraSpacing,
      onToken: (pi, ti, isLong, rect) {
        final isTitle = pi < 0;
        final toks = isTitle ? _c.tokenize(_c.state.title) : _c.tokensAt(pi);
        final tk = ti < toks.length ? toks[ti] : const ReadingToken('', false);
        final text = isTitle
            ? _c.state.title
            : (pi < _c.state.paragraphs.length ? _c.state.paragraphs[pi] : '');
        _onToken(tk, isLong, text, pi, ti, rect, isTitle: isTitle);
      },
      onEmptyTap: _toggleChrome,
    );
  }

  /// 正文缺失时的占位：标题等元信息照常展示，正文区给说明与「打开原文」。
  Widget _noBody(AppConfigService cfg, GoReaderPalette pal) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + Go.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReadingCover(
            controller: _c,
            pal: pal,
            fontFamily: cfg.readerFont,
            onTitleToken: (ti, isLong, rect) {
              final toks = _c.tokenize(_c.state.title);
              final tk = ti < toks.length ? toks[ti] : const ReadingToken('', false);
              _onToken(tk, isLong, _c.state.title, -1, ti, rect, isTitle: true);
            },
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Go.sp6),
            padding: const EdgeInsets.all(Go.sp6),
            decoration: BoxDecoration(color: pal.card, borderRadius: BorderRadius.circular(Go.rMd)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正文未缓存', style: TextStyle(fontSize: Go.fsH2, fontWeight: FontWeight.w600, color: pal.ink)),
                const SizedBox(height: Go.sp2),
                Text('这篇文章暂时没有缓存正文，可以打开原文阅读，或稍后重新进入本页加载。',
                    style: TextStyle(fontSize: Go.fsBodySm, color: pal.secondary, height: Go.lhRelaxed)),
                if (_c.state.sourceUrl.isNotEmpty) ...[
                  const SizedBox(height: Go.sp5),
                  GestureDetector(
                    onTap: _openOriginal,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp3),
                      decoration: BoxDecoration(color: pal.accent, borderRadius: BorderRadius.circular(Go.rFull)),
                      child: Text('打开原文', style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 点词浮窗的锚定上下文：pi/ti 同时用于「再点同一个词 = 收起」的判定与收录入库。
class _WordPop {
  final String query;
  final String sentence;
  final int pi;
  final int ti;
  final Rect rect; // 词的屏幕包围盒
  const _WordPop(this.query, this.sentence, this.pi, this.ti, this.rect);
}
