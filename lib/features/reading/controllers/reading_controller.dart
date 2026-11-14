import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/reading/models/reading_state.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/tts_service.dart';

/// 阅读器状态与交互的核心：
///
/// - 正文加载 / AI 精选 / 图片重试
/// - 分词缓存、选区（点击多选 + 长按整句/整段）
/// - 全文朗读（句表、跟读高亮、自动滚动）
///
/// 页面只负责组合 UI（弹层、SnackBar 等需要 BuildContext 的动作留在 screen）。
/// 选区与朗读句号用独立 [ValueNotifier] 通知，避免整页重建。
class ReadingController extends ChangeNotifier {
  ReadingController({
    required WidgetRef ref,
    required int? articleId,
    required String? guid,
    required String? title,
    this.focusPara = -1,
    this.focusTok = -1,
    this.onMessage,
  })  : _ref = ref,
        state = ReadingState(guid: guid ?? '', title: title ?? '', articleId: articleId ?? 0) {
    _tts = _ref.read(ttsProvider);
    _tts.playing.addListener(_onTtsChanged);
    _tts.segment.addListener(_onTtsSegment);
    load();
  }

  final WidgetRef _ref;

  /// 需要弹 SnackBar 的轻提示（朗读失败等）；由页面注入。
  final void Function(String message)? onMessage;

  final int focusPara;
  final int focusTok;

  final ReadingState state;

  bool _disposed = false;

  // ================= 加载 =================

  bool get loading => state.loading;
  String get error => state.error;

  Future<void> load() async {
    state.loading = true;
    state.error = '';
    _notify();
    try {
      final db = _ref.read(dbProvider);
      // 不取 html：阅读器只用 plainText/blocks；source/publishedAt 等云端元信息供页头展示。
      const cols =
          'id, title, sourceUrl, wordCount, plainText, blocks, source, publishedAt, expiresAt, cachedAt, status, summary, remoteId';
      Map<String, dynamic>? row;
      if (state.articleId != 0) {
        row = await _first(db, 'SELECT $cols FROM articles WHERE id = ?', [state.articleId]);
      } else {
        row = await _first(db, 'SELECT $cols FROM articles WHERE guid = ?', [state.guid]);
      }
      if (_disposed) return;
      if (row == null) {
        state.error = '未找到正文，请返回列表重新抓取';
      } else {
        _applyRow(row);
      }
      if (_disposed) return;
      await _loadCuratedIfAny();
    } catch (e) {
      state.error = errText(e);
    } finally {
      if (!_disposed) {
        state.loading = false;
        _notify();
      }
    }
  }

  Future<Map<String, dynamic>?> _first(dynamic db, String sql, List<dynamic> args) async {
    final rows = await db.select(sql, args);
    return rows.isEmpty ? null : rows.first;
  }

  void _applyRow(Map<String, dynamic> row) {
    state.articleId = row['id'] as int? ?? 0;
    state.plain = row['plainText'] as String? ?? '';
    state.sourceUrl = row['sourceUrl'] as String? ?? '';
    state.source = row['source'] as String? ?? '';
    state.status = row['status'] as String? ?? '';
    state.publishedAt = (row['publishedAt'] as num?)?.toInt();
    state.cachedAt = (row['cachedAt'] as num?)?.toInt();
    state.wordCount = row['wordCount'] as int? ?? 0;
    if (state.title.isEmpty) state.title = row['title'] as String? ?? '';
    List<ArticleBlock> bs = [];
    final raw = row['blocks'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        bs = (jsonDecode(raw) as List).map((e) => ArticleBlock.fromJson(e)).toList();
      } catch (_) {
        bs = [];
      }
    }
    if (bs.isEmpty) {
      bs = (state.plain.split(_reParaSplit).map((s) => s.trim()).where((s) => s.isNotEmpty))
          .map((t) => ArticleBlock(type: 'p', text: t))
          .toList();
    }
    state.blocks = bs;
    state.error = '';
    flashPara = focusPara;
    flashTok = focusTok;
    if (focusPara >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        final ctx = paraKey(focusPara).currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0.15, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
        }
      });
    }
  }

  Future<void> _loadCuratedIfAny() async {
    state.curatedBlocks = null;
    state.useCurated = false;
    if (state.articleId == 0) return;
    try {
      final c = await _ref.read(dbProvider).loadCurated(state.articleId);
      if (_disposed) return;
      if (c != null) {
        state.curatedBlocks = c.map((e) => ArticleBlock.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        state.useCurated = focusPara < 0;
      }
    } catch (_) {}
  }

  // ================= tokenize =================
  static final _reZeroWidth = RegExp(r'[\u200b-\u200f\u2060\u00ad\ufeff]');
  static final _reToken = RegExp(r"(\s+|[A-Za-z][A-Za-z'’-]*[A-Za-z]|[A-Za-z]|[^A-Za-z\s]+)");
  static final _reSpaceOnly = RegExp(r'^\s+$');
  static final _reNonNewline = RegExp(r'[^\n\t]');
  static final _reWordOnly = RegExp(r"^[A-Za-z][A-Za-z'’-]*$");
  static final _reParaSplit = RegExp(r'\n\s*\n');
  static final _reSentenceEnd = RegExp(r'[.!?\u3002\uff01\uff1f]');

  List<ReadingToken> tokenize(String? p) {
    if (p == null || p.isEmpty) return [];
    final out = <ReadingToken>[];
    final s = p.replaceAll(_reZeroWidth, ' ');
    for (final m in _reToken.allMatches(s)) {
      var t = m.group(0)!;
      if (_reSpaceOnly.hasMatch(t)) {
        // 空白统一换成普通空格（1:1 替换，token 长度与原文对齐，偏移/二分/选区都依赖这一点）。
        // 不能用 U+00A0：NBSP 不可断行，整段只剩零个换行机会，ICU 只能从单词中间断。
        t = t.replaceAll(_reNonNewline, ' ');
      }
      out.add(ReadingToken(t, _reWordOnly.hasMatch(t)));
    }
    return out;
  }

  String sentenceAround(String p, int ti) {
    final toks = tokenize(p);
    if (toks.isEmpty) return p.trim();
    var start = 0;
    for (var i = 0; i < ti && i < toks.length; i++) {
      start += toks[i].text.length;
    }
    final off = start < p.length ? start : p.length;
    var sIdx = off;
    while (sIdx > 0) {
      final ch = p[sIdx - 1];
      if (_reSentenceEnd.hasMatch(ch)) break;
      sIdx--;
    }
    final rest = p.substring(off);
    final m = RegExp(r"^[A-Za-z'\u2019-]*\s*").firstMatch(rest);
    final from = off + (m?.group(0)?.length ?? 0);
    final tail = from < p.length ? p.substring(from) : '';
    final mm = RegExp(r'^[^.!?。！？]*').firstMatch(tail);
    var e = from + (mm?.group(0)?.length ?? 0);
    final tail2 = e < p.length ? p.substring(e) : '';
    final dot = RegExp(r'^[.!?。！？]+').firstMatch(tail2);
    if (dot != null) e += dot.group(0)!.length;
    final sentence = p.substring(sIdx, e.clamp(sIdx, p.length)).trim();
    return sentence.isNotEmpty ? sentence : p.trim();
  }

  /// 分词与字符偏移表缓存：旧实现在 build 里逐段重新分词，改为按 blocks 身份缓存。
  List<ArticleBlock>? _tokBlocks;
  List<ArticleBlock>? _tokCurated;
  bool _tokUseCurated = false;
  List<List<ReadingToken>> _paraToks = const [];
  List<List<int>> _paraStarts = const [];

  List<ReadingToken> tokensAt(int pi) => pi >= 0 && pi < _paraToks.length ? _paraToks[pi] : const [];
  List<int> startsAt(int pi) => pi >= 0 && pi < _paraStarts.length ? _paraStarts[pi] : const [];

  void syncTokens() {
    final blocks = state.blocks;
    final curated = state.curatedBlocks;
    final use = state.useCurated;
    if (identical(_tokBlocks, blocks) && identical(_tokCurated, curated) && _tokUseCurated == use) return;
    _tokBlocks = blocks;
    _tokCurated = curated;
    _tokUseCurated = use;
    final paras = state.paragraphs;
    _paraToks = [for (final p in paras) tokenize(p)];
    _paraStarts = [for (final t in _paraToks) _tokenOffsets(t)];
  }

  /// 各 token 在整段文本中的起始字符偏移（含 2 字符首行缩进），供二分查找定位。
  static List<int> _tokenOffsets(List<ReadingToken> toks) {
    final out = <int>[];
    var acc = 2;
    for (final t in toks) {
      out.add(acc);
      acc += t.text.length;
    }
    return out;
  }

  // ================= 选区 =================
  final Set<int> _sel = <int>{};
  final ValueNotifier<int> _selVer = ValueNotifier<int>(0);

  /// 选区版本号：正文各段只在自己那段命中时重建，整页不重建。
  ValueNotifier<int> get selVer => _selVer;
  Set<int> get sel => _sel;

  bool selectMode = false;
  String selText = '';
  int selPi = -1;
  int selTi = -1;

  static int _selKey(int pi, int ti) => (pi << 20) | ti;

  /// 按 key 排序即为文档顺序，因此不必额外维护插入顺序。
  String get selectedText {
    if (_sel.isEmpty) return '';
    final keys = _sel.toList()..sort();
    final out = <String>[];
    for (final k in keys) {
      final pi = k >> 20;
      final ti = k & 0xFFFFF;
      final toks = tokensAt(pi);
      if (ti < toks.length) out.add(toks[ti].text);
    }
    return out.join(' ').trim();
  }

  /// 当前应展示/处理的选区文本：点选优先，其次长按得到的句子/段落。
  String get effectiveSelection => selectedText.isNotEmpty ? selectedText : selText;

  void toggleSelToken(int pi, int ti) {
    final k = _selKey(pi, ti);
    if (_sel.contains(k)) {
      _sel.remove(k);
    } else {
      _sel.add(k);
    }
    if (!_disposed) _selVer.value++;
  }

  void toggleSelectMode() {
    selectMode = !selectMode;
    if (!selectMode && _sel.isNotEmpty) {
      _sel.clear();
      if (!_disposed) _selVer.value++;
    }
    _notify();
  }

  void setSelectionText(String text, int pi, int ti) {
    final t = text.trim();
    if (t.isEmpty) return;
    selPi = pi;
    selTi = ti;
    selText = t.length > 400 ? t.substring(0, 400) : t;
    if (!_disposed) _selVer.value++;
  }

  void clearSelection() {
    if (_disposed) return;
    if (_sel.isNotEmpty) {
      _sel.clear();
      _selVer.value++;
    }
    final hadText = selText.isNotEmpty;
    final wasMode = selectMode;
    selText = '';
    selPi = -1;
    selTi = -1;
    selectMode = false;
    if (hadText) _selVer.value++;
    if (wasMode) _notify();
  }

  /// 长按段落：整段入选区（超过 400 字截断）。
  void onParaLongPress(int pi) {
    final paras = state.paragraphs;
    if (pi >= paras.length) return;
    final para = paras[pi];
    if (para.trim().isEmpty) return;
    setSelectionText(para.trim(), pi, -1);
  }

  /// 选区锚点 (pi, ti)：点选模式取最小 key 反解；长按整句用 selPi/selTi。
  ({int pi, int ti}) selAnchor() {
    int pi = selPi, ti = selTi;
    final picked = selectedText;
    if (picked.isNotEmpty && _sel.isNotEmpty) {
      final k = _sel.reduce((a, b) => a < b ? a : b);
      pi = k >> 20;
      ti = k & 0xFFFFF;
    }
    return (pi: pi, ti: ti);
  }

  /// 入库的 sentence 字段：点选模式用锚点反解所在句；
  /// 长按路径的 selText 本身就是整句/整段/标题，直接沿用，避免残留的锚点串段。
  String selSentence(String fallback) {
    if (_sel.isEmpty) return fallback;
    final a = selAnchor();
    if (a.pi >= 0 && a.pi < state.paragraphs.length) {
      final s = sentenceAround(state.paragraphs[a.pi], a.ti);
      if (s.isNotEmpty) return s;
    }
    return fallback;
  }

  // ================= 图片重试 =================
  final Map<int, int> _imgRetry = {};
  final Set<int> _imgErr = {};

  bool imageFailed(int bi) => _imgErr.contains(bi);

  String imageSrc(ArticleBlock b, int bi) {
    final src = b.src ?? '';
    if (src.isEmpty || src.startsWith('data:')) return src;
    final r = _imgRetry[bi];
    if (r == null) return src;
    return '$src${src.contains('?') ? '&' : '?'}_cb=$r';
  }

  void onImageError(int bi) {
    final r = _imgRetry[bi] ?? 0;
    if (r < 2) {
      _imgRetry[bi] = r + 1;
    } else {
      _imgErr.add(bi);
    }
    _notify();
  }

  // ================= 滚动 / 段落 key =================
  final ScrollController scrollController = ScrollController();
  final Map<int, GlobalKey> _paraKeys = {};
  int flashPara = -1;
  int flashTok = -1;

  GlobalKey paraKey(int pi) => _paraKeys.putIfAbsent(pi, () => GlobalKey());

  // ================= AI 精选 =================
  bool curating = false;

  /// 对比精选前后的段落数与字数，生成「去除了多少」的结果摘要。
  String curateSummary(List<ArticleBlock> before, List<ArticleBlock> after) {
    int paras(List<ArticleBlock> bs) => bs.where((b) => b.type == 'p').length;
    int chars(List<ArticleBlock> bs) => bs.where((b) => b.type == 'p').fold<int>(0, (s, b) => s + (b.text ?? '').length);
    String delta(int from, int to) {
      if (from <= 0) return '';
      final d = ((1 - to / from) * 100).round();
      return d >= 0 ? '（-$d%）' : '（+${-d}%）';
    }

    final bp = paras(before), ap = paras(after);
    final bc = chars(before), ac = chars(after);
    return 'AI 精选完成：段落 $bp → $ap${delta(bp, ap)}，字数 $bc → $ac${delta(bc, ac)}';
  }

  void toggleCurated() {
    state.useCurated = !state.useCurated;
    clearSelection();
    _notify();
  }

  /// 重新精选。返回摘要；返回 null 表示「无可用正文，已还原原文」。
  Future<String?> runCurate() async {
    if (state.articleId == 0) return '';
    curating = true;
    _notify();
    try {
      final res = await _ref.read(curateProvider).curate(state.blocks);
      if (_disposed) return '';
      if (res.isEmpty) {
        await _ref.read(dbProvider).clearCurated(state.articleId);
        if (_disposed) return '';
        state.curatedBlocks = null;
        state.useCurated = false;
        _notify();
        return null;
      }
      await _ref.read(dbProvider).saveCurated(state.articleId, res.map((b) => b.toJson()).toList());
      if (_disposed) return '';
      final summary = curateSummary(state.blocks, res);
      state.curatedBlocks = res;
      state.useCurated = true;
      _notify();
      clearSelection();
      return summary;
    } finally {
      if (!_disposed) {
        curating = false;
        _notify();
      }
    }
  }

  Future<void> removeCurated() async {
    if (state.articleId == 0) return;
    await _ref.read(dbProvider).clearCurated(state.articleId);
    if (_disposed) return;
    state.curatedBlocks = null;
    state.useCurated = false;
    _notify();
    clearSelection();
  }

  // ================= 朗读 =================
  late final TtsService _tts;

  bool ttsPlaying = false;

  /// 「正在生成语音…」：只表示在等第一段 Edge 合成音频就绪，由 playing 变 true 或失败收掉。
  bool ttsSynthesizing = false;

  /// 全文朗读模式（跟读高亮 + 底部状态胶囊）。选区朗读/词卡试听不进入该模式。
  bool ttsArticle = false;

  /// 全文朗读句表：按段落切句，记录每句的 token 区间供跟读高亮回映。
  /// 播放期间保持身份稳定（ReadingParagraph 靠 identical 判断）。
  List<TtsSegment> segs = const [];

  /// 当前朗读句下标（-1 空闲）：段落级听众各自过滤，避免整页重建。
  final ValueNotifier<int> _ttsSegVer = ValueNotifier<int>(-1);
  ValueNotifier<int> get ttsSegVer => _ttsSegVer;

  /// 跟读滚动：只在「段落变了 + 不在视口 + 用户没在拖 + 不是首句」时才 ensureVisible。
  int _ttsPara = -1;
  bool _ttsFollowArmed = false;

  void _onTtsChanged() {
    if (_disposed) return;
    final playing = _tts.isPlaying;
    ttsPlaying = playing;
    if (playing) {
      ttsSynthesizing = false; // 第一段已开播，收掉「生成中」
    } else if (!ttsSynthesizing) {
      // 自然播完或外部停止。注意 speakSegments 启动时会先内部 stop() 一次
      //（playing=false 前奏），那一下 ttsSynthesizing 还是 true，不能在此清全文模式。
      ttsArticle = false;
      _ttsPara = -1;
      _ttsFollowArmed = false;
    }
    if (!playing) _ttsSegVer.value = -1;
    _notify();
  }

  /// 句号变化：只 bump 一个版本号让相关段落自行重建，整页不重建；
  /// 同时在「段落切换且不在视口」时做一次温和的自动滚动。
  void _onTtsSegment() {
    if (_disposed) return;
    final idx = _tts.segment.value;
    // 只有全文朗读的句表才驱动高亮：选区朗读/音色试听的 segment 下标
    // 指向的是别的句表，直接拿来上色会错位。
    final forArticle = ttsArticle && idx >= 0 && idx < segs.length;
    _ttsSegVer.value = forArticle ? idx : -1;
    if (!forArticle) return;
    final pi = segs[idx].pi;
    // 首句不滚动（用户刚点朗读，视口通常已在开头）；同段内换句不滚。
    if (!_ttsFollowArmed) {
      _ttsFollowArmed = true;
      _ttsPara = pi;
      return;
    }
    if (pi == _ttsPara) return;
    _ttsPara = pi;
    // 用户正在拖动时绝不抢滚动。
    if (scrollController.hasClients && scrollController.position.isScrollingNotifier.value) return;
    final ctx = _paraKeys[pi]?.currentContext;
    if (ctx == null) return;
    final paraRo = ctx.findRenderObject();
    if (paraRo is! RenderBox || !paraRo.hasSize) return;
    final scrollable = Scrollable.maybeOf(ctx);
    final vpRo = scrollable?.context.findRenderObject();
    if (vpRo is! RenderBox || !vpRo.hasSize) return;
    final paraRect = paraRo.localToGlobal(Offset.zero) & paraRo.size;
    final vpRect = vpRo.localToGlobal(Offset.zero) & vpRo.size;
    // 已有交集（哪怕只露一点）就不滚，避免和用户的手打架。
    const grace = 8.0;
    final visible = paraRect.bottom > vpRect.top + grace && paraRect.top < vpRect.bottom - grace;
    if (visible) return;
    Scrollable.ensureVisible(ctx, alignment: 0.25, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
  }

  /// 选区/词卡朗读前清掉全文跟读状态，避免 segment 下标错位上色。
  void resetForSpeechPreview() {
    if (_disposed) return;
    ttsArticle = false;
    ttsSynthesizing = false;
    segs = const [];
    _ttsSegVer.value = -1;
  }

  Future<void> readText(String text) async {
    if (text.trim().isEmpty) return;
    resetForSpeechPreview();
    await _tts.stop();
    try {
      await _tts.speak(text);
    } catch (e) {
      onMessage?.call('朗读失败：$e');
    }
  }

  Future<void> readSelection() async {
    final text = effectiveSelection;
    if (text.isEmpty) return;
    await readText(text);
    clearSelection();
  }

  /// 词卡「朗读」/音色试听：不进全文跟读模式。
  Future<void> speakPreview(String text) async {
    resetForSpeechPreview();
    try {
      await _tts.speak(text);
    } catch (e) {
      onMessage?.call('朗读失败：$e');
    }
  }

  Future<void> toggleReadAloud() async {
    if (ttsPlaying || ttsSynthesizing) {
      await _tts.stop();
      if (_disposed) return;
      ttsPlaying = false;
      ttsSynthesizing = false;
      ttsArticle = false; // 取消后残留 true 会让后续试听错点亮旧句表
      _notify();
      return;
    }
    final built = _buildSegs();
    if (built.isEmpty) return;
    clearSelection(); // 全文朗读时收起选区条，状态胶囊不与它叠在一起
    segs = built;
    ttsArticle = true;
    ttsSynthesizing = true; // 等第一段音频；playing 变 true 时由监听收掉
    _ttsPara = -1;
    _ttsFollowArmed = false;
    _notify();
    try {
      await _tts.speakSegments([for (final s in segs) s.text]);
    } catch (e) {
      if (_disposed) return;
      ttsSynthesizing = false;
      ttsPlaying = false;
      ttsArticle = false;
      _notify();
      onMessage?.call('朗读失败：$e');
    }
  }

  /// 句末标点后的收尾引号/括号（与 TtsService._closers 对齐）。
  static final _reClosersOnly = RegExp('^["\'”’)\\]]+\$');

  /// 把当前正文切成句表：逐段扫 token，句末判定与 TtsService.splitSentences 同规则——
  /// token 里出现 .!?（其后只允许收尾符号），且下一个 token 是空白或段落结束。
  List<TtsSegment> _buildSegs() {
    syncTokens();
    final out = <TtsSegment>[];
    final paras = state.paragraphs;
    for (var pi = 0; pi < paras.length; pi++) {
      final toks = tokensAt(pi);
      if (toks.isEmpty) continue;
      var start = 0;
      for (var ti = 0; ti < toks.length; ti++) {
        final end = _segEndAt(toks, ti);
        if (end < 0) continue;
        final text = _segText(toks, start, end);
        if (text.isNotEmpty) out.add(TtsSegment(text, pi, start, end));
        start = end + 1;
        ti = end;
      }
      // 段尾没有句末标点的残句（"To be continued"）单独成句。
      if (start < toks.length) {
        final text = _segText(toks, start, toks.length - 1);
        if (text.isNotEmpty) out.add(TtsSegment(text, pi, start, toks.length - 1));
      }
    }
    return out;
  }

  /// token [ti] 是否为句末：是则返回其下标，否则 -1。
  /// 标点串（`."`、`...`、`).`）在分词里是一个 token，按**最后一个** .!? 判断，
  /// 其后只允许收尾引号/括号——这样 `3.5`、`e.g` 这类内部点号不会误切。
  int _segEndAt(List<ReadingToken> toks, int ti) {
    final t = toks[ti].text;
    var p = -1;
    for (var i = t.length - 1; i >= 0; i--) {
      if ('.!?。！？'.contains(t[i])) {
        p = i;
        break;
      }
    }
    if (p < 0) return -1;
    final rest = t.substring(p + 1);
    if (rest.isNotEmpty && !_reClosersOnly.hasMatch(rest)) return -1;
    if (ti + 1 >= toks.length) return ti; // 段落结束
    if (_reSpaceOnly.hasMatch(toks[ti + 1].text)) return ti; // 后随空白
    return -1;
  }

  /// token [from]..[to] 拼成句文本：保留内部空白（TTS 需要正常间距），仅 trim 两端。
  static String _segText(List<ReadingToken> toks, int from, int to) {
    final buf = StringBuffer();
    for (var k = from; k <= to && k < toks.length; k++) {
      buf.write(toks[k].text);
    }
    return buf.toString().trim();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // Riverpod 3 禁止在 dispose 里用 ref（会抛 StateError，导致 stop() 根本没执行），
    // 所以 TtsService 在构造时缓存，dispose 只用缓存实例。
    _disposed = true;
    _tts.playing.removeListener(_onTtsChanged);
    _tts.segment.removeListener(_onTtsSegment);
    _tts.stop();
    _ttsSegVer.dispose();
    _selVer.dispose();
    scrollController.dispose();
    super.dispose();
  }
}
