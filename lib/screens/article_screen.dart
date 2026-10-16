import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/models/models.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/tts_service.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';
import 'package:url_launcher/url_launcher.dart';

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

class _Tok {
  final String text;
  final bool word;
  const _Tok(this.text, this.word);
}

class _ArticleScreenState extends ConsumerState<ArticleScreen> {
  List<ArticleBlock> _blocks = [];
  List<ArticleBlock>? _curatedBlocks;
  bool _useCurated = false;
  bool _curating = false;
  String _plain = '';
  String _title = '';
  String _guid = '';
  int _articleId = 0;
  String _sourceUrl = '';
  String _source = ''; // 云端来源名（articles.source），优先于 sourceUrl 的 host
  String _status = ''; // 'gone' 表示源已下线，仅显示本地缓存
  int? _publishedAt; // 毫秒时间戳
  int? _cachedAt; // 毫秒时间戳
  int _wordCount = 0;
  bool _loading = true;
  String _error = '';

  bool _showSettings = false;
  String _selText = '';
  bool _selectMode = false;
  int _selPi = -1;
  int _selTi = -1;

  /// 选中词用 (pi << 20 | ti) 编码进 Set：判定 O(1)（旧实现是列表线性扫描）。
  final Set<int> _sel = <int>{};
  final ValueNotifier<int> _selVer = ValueNotifier<int>(0);

  /// 分词与字符偏移表缓存：旧实现在 build 里逐段重新分词，改为按 blocks 身份缓存。
  List<ArticleBlock>? _tokBlocks;
  List<ArticleBlock>? _tokCurated;
  bool _tokUseCurated = false;
  List<List<_Tok>> _paraToks = const [];
  List<List<int>> _paraStarts = const [];

  bool _ttsPlaying = false;
  bool _ttsSynthesizing = false;

  int _flashPara = -1;
  int _flashTok = -1;
  final _scrollCtrl = ScrollController();
  final Map<int, int> _imgRetry = {}; // blockIndex -> retry count
  final Set<int> _imgErr = {};
  final Map<int, GlobalKey> _paraKeys = {};

  List<ArticleBlock> get _activeBlocks => (_useCurated && _curatedBlocks != null) ? _curatedBlocks! : _blocks;

  List<String> get _paragraphs =>
      _activeBlocks.where((b) => b.type == 'p').map((b) => b.text ?? '').toList();

  late final TtsService _tts;

  @override
  void initState() {
    super.initState();
    _guid = widget.guid ?? '';
    _title = widget.title ?? '';
    _load();
    _tts = ref.read(ttsProvider);
    _tts.playing.addListener(_onTtsChanged);
  }

  void _onTtsChanged() {
    if (!mounted) return;
    setState(() {
      _ttsPlaying = ref.read(ttsProvider).isPlaying;
      if (!_ttsPlaying) _ttsSynthesizing = false;
    });
  }

  @override
  void dispose() {
    // Riverpod 3 禁止在 dispose 里用 ref（会抛 StateError，导致 stop() 根本没执行）
    _tts.playing.removeListener(_onTtsChanged);
    _tts.stop();
    _scrollCtrl.dispose();
    super.dispose();
  }

  int? get _id => widget.articleId;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final db = ref.read(dbProvider);
      // 不取 html：阅读器只用 plainText/blocks；source/publishedAt 等云端元信息供页头展示。
      const cols =
          'id, title, sourceUrl, wordCount, plainText, blocks, source, publishedAt, expiresAt, cachedAt, status, summary, remoteId';
      Map<String, dynamic>? row;
      if (_id != null) {
        row = await _first(db, 'SELECT $cols FROM articles WHERE id = ?', [_id]);
      } else {
        row = await _first(db, 'SELECT $cols FROM articles WHERE guid = ?', [_guid]);
      }
      if (row == null) {
        _error = '未找到正文，请返回列表重新抓取';
      } else {
        _applyRow(row);
      }
      await _loadCuratedIfAny();
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>?> _first(dynamic db, String sql, List<dynamic> args) async {
    final rows = await db.select(sql, args);
    return rows.isEmpty ? null : rows.first;
  }

  void _applyRow(Map<String, dynamic> row) {
    _articleId = row['id'] as int? ?? 0;
    _plain = row['plainText'] as String? ?? '';
    _sourceUrl = row['sourceUrl'] as String? ?? '';
    _source = row['source'] as String? ?? '';
    _status = row['status'] as String? ?? '';
    _publishedAt = (row['publishedAt'] as num?)?.toInt();
    _cachedAt = (row['cachedAt'] as num?)?.toInt();
    _wordCount = row['wordCount'] as int? ?? 0;
    if (_title.isEmpty) _title = row['title'] as String? ?? '';
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
      bs = (_plain.split(_reParaSplit).map((s) => s.trim()).where((s) => s.isNotEmpty)).map((t) => ArticleBlock(type: 'p', text: t)).toList();
    }
    _blocks = bs;
    _error = '';
    _flashPara = widget.focusPara;
    _flashTok = widget.focusTok;
    if (widget.focusPara >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _paraKeys[widget.focusPara]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0.15, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
        }
      });
    }
  }

  Future<void> _loadCuratedIfAny() async {
    _curatedBlocks = null;
    _useCurated = false;
    if (_articleId == 0) return;
    try {
      final c = await ref.read(dbProvider).loadCurated(_articleId);
      if (c != null) {
        _curatedBlocks = c.map((e) => ArticleBlock.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        _useCurated = widget.focusPara < 0;
      }
    } catch (_) {}
  }

  // ================= tokenize（对齐 article.vue）=================
  static final _reZeroWidth = RegExp(r'[\u200b-\u200f\u2060\u00ad\ufeff]');
  static final _reToken = RegExp(r"(\s+|[A-Za-z][A-Za-z'’-]*[A-Za-z]|[A-Za-z]|[^A-Za-z\s]+)");
  static final _reSpaceOnly = RegExp(r'^\s+$');
  static final _reNonNewline = RegExp(r'[^\n\t]');
  static final _reWordOnly = RegExp(r"^[A-Za-z][A-Za-z'’-]*$");
  static final _reParaSplit = RegExp(r'\n\s*\n');
  static final _reSentenceEnd = RegExp(r'[.!?\u3002\uff01\uff1f]');

  List<_Tok> _tokenize(String? p) {
    if (p == null || p.isEmpty) return [];
    final out = <_Tok>[];
    var s = p.replaceAll(_reZeroWidth, ' ');
    for (final m in _reToken.allMatches(s)) {
      var t = m.group(0)!;
      if (_reSpaceOnly.hasMatch(t)) {
        t = t.replaceAll(_reNonNewline, '\u00A0');
      }
      out.add(_Tok(t, _reWordOnly.hasMatch(t)));
    }
    return out;
  }

  String _sentenceAround(String p, int ti) {
    final toks = _tokenize(p);
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

  // ================= 选区 =================
  static int _selKey(int pi, int ti) => (pi << 20) | ti;

  /// 按 key 排序即为文档顺序，因此不必额外维护插入顺序。
  String get _selectedText {
    if (_sel.isEmpty) return '';
    final keys = _sel.toList()..sort();
    final out = <String>[];
    for (final k in keys) {
      final pi = k >> 20;
      final ti = k & 0xFFFFF;
      final toks = pi < _paraToks.length ? _paraToks[pi] : const <_Tok>[];
      if (ti < toks.length) out.add(toks[ti].text);
    }
    return out.join(' ').trim();
  }

  /// 只更新集合并自增版本号：正文整体不重建，由各段自行判断是否需要重绘。
  void _toggleSelToken(int pi, int ti) {
    final k = _selKey(pi, ti);
    if (_sel.contains(k)) {
      _sel.remove(k);
    } else {
      _sel.add(k);
    }
    _selVer.value++;
  }

  void _clearSelection() {
    if (_sel.isNotEmpty) {
      _sel.clear();
      _selVer.value++;
    }
    if (_selText.isNotEmpty || _selectMode) {
      setState(() {
        _selText = '';
        _selectMode = false;
      });
    }
  }

  void _syncToks() {
    final blocks = _blocks;
    final curated = _curatedBlocks;
    final use = _useCurated;
    if (identical(_tokBlocks, blocks) && identical(_tokCurated, curated) && _tokUseCurated == use) return;
    _tokBlocks = blocks;
    _tokCurated = curated;
    _tokUseCurated = use;
    final paras = _paragraphs;
    _paraToks = [for (final p in paras) _tokenize(p)];
    _paraStarts = [for (final t in _paraToks) _tokenOffsets(t)];
  }

  /// 各 token 在整段文本中的起始字符偏移（含 2 字符首行缩进），供二分查找定位。
  static List<int> _tokenOffsets(List<_Tok> toks) {
    final out = <int>[];
    var acc = 2;
    for (final t in toks) {
      out.add(acc);
      acc += t.text.length;
    }
    return out;
  }

  void _openWord(String text, {String sentence = '', int paraIndex = -1, int tokIndex = -1}) {
    final clean = ArticleScreen.cleanQueryText(text);
    if (clean.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => _WordCardDialog(
        word: clean,
        sentence: sentence.isNotEmpty ? sentence : clean,
        articleGuid: _guid,
        articleTitle: _title,
        sourceLabel: _sourceHost,
        paraIndex: paraIndex,
        tokIndex: tokIndex,
        onClose: () => Navigator.pop(c),
        onSpeak: (w) async {
          try {
            await ref.read(ttsProvider).speak(w);
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('朗读失败：$e')));
          }
        },
      ),
    );
  }

  void _onTok(_Tok tk, bool isLong, String ctx, int pi, int ti, {bool isTitle = false}) {
    if (!tk.word) return;
    if (_selectMode) {
      _toggleSelToken(pi, ti);
      return;
    }
    if (isLong) {
      if (isTitle) {
        _selPi = -1;
        _selTi = -1;
        final t = _title.trim();
        if (t.isNotEmpty) setState(() => _selText = t.length > 400 ? t.substring(0, 400) : t);
      } else {
        final sentence = _sentenceAround(ctx, ti);
        if (sentence.isNotEmpty) {
          _selPi = pi;
          _selTi = ti;
          setState(() => _selText = sentence.length > 400 ? sentence.substring(0, 400) : sentence);
        }
      }
      return;
    }
    final sentence = isTitle ? _title.trim() : _sentenceAround(ctx, ti);
    ref
        .read(vocabProvider)
        .recordOccurrence(tk.text, sentence, _guid, _title, _sourceHost, pi, ti)
        .catchError((_) {});
    ref.read(vocabRevisionProvider.notifier).bump();
    _openWord(tk.text, sentence: sentence, paraIndex: pi, tokIndex: ti);
  }

  /// 页头来源：优先云端 `source`，其次 sourceUrl 的 host（去掉 www），兜底「收录文章」。
  String get _sourceHost {
    final s = _source.trim();
    if (s.isNotEmpty) return s;
    if (_sourceUrl.isEmpty) return '收录文章';
    try {
      final host = Uri.parse(_sourceUrl).host.replaceFirst(RegExp(r'^www\.'), '');
      return host.isEmpty ? '收录文章' : host;
    } catch (_) {
      return '收录文章';
    }
  }

  /// 日期：publishedAt 优先，其次 cachedAt（均为毫秒时间戳，本地时区 MM-dd）；都没有则「—」。
  String get _dateText {
    final ts = _publishedAt ?? _cachedAt;
    if (ts == null || ts <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '$mm-$dd';
  }

  int get _readMins => _wordCount > 0 ? (_wordCount / 60).round().clamp(1, 9999) : 0;

  // ================= 朗读 =================
  Future<void> _readText(String text) async {
    if (text.trim().isEmpty) return;
    await ref.read(ttsProvider).stop();
    setState(() => _ttsSynthesizing = true);
    try {
      await ref.read(ttsProvider).speak(text);
      if (mounted) {
        setState(() {
          _ttsSynthesizing = false;
          _ttsPlaying = ref.read(ttsProvider).isPlaying;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _ttsSynthesizing = false;
          _ttsPlaying = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('朗读失败：$e')));
      }
    }
  }

  Future<void> _toggleReadAloud() async {
    if (_ttsPlaying || _ttsSynthesizing) {
      await ref.read(ttsProvider).stop();
      if (mounted) {
        setState(() {
          _ttsPlaying = false;
          _ttsSynthesizing = false;
        });
      }
      return;
    }
    final full = _paragraphs.join('\n\n').trim();
    if (full.isEmpty) return;
    await _readText(full);
  }

  Future<void> _readSelection() async {
    final text = _selectedText.isNotEmpty ? _selectedText : _selText;
    if (text.isEmpty) return;
    await _readText(text);
    _clearSelection();
  }

  // ================= AI 精选 =================
  Future<void> _onCurateTap() async {
    if (_curating) return;
    if (_curatedBlocks == null) {
      await _runCurate();
      return;
    }
    final idx = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_curatedBlocks != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp4, Go.sp5, Go.sp2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_curateSummary(_blocks, _curatedBlocks!), style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
                ),
              ),
            ListTile(title: Text(_useCurated ? '切换到原文' : '切换到 AI 精选版'), onTap: () => Navigator.pop(c, 0)),
            ListTile(title: const Text('重新精选'), onTap: () => Navigator.pop(c, 1)),
            ListTile(title: const Text('删除精选版（还原原文）'), onTap: () => Navigator.pop(c, 2)),
          ],
        ),
      ),
    );
    if (idx == 0) {
      setState(() {
        _useCurated = !_useCurated;
      });
      _clearSelection();
    } else if (idx == 1) {
      await _runCurate();
    } else if (idx == 2) {
      await _removeCurated();
    }
  }

  Future<void> _runCurate() async {
    if (_articleId == 0) return;
    setState(() => _curating = true);
    try {
      final res = await ref.read(curateProvider).curate(_blocks);
      if (!mounted) return;
      if (res.isEmpty) {
        await ref.read(dbProvider).clearCurated(_articleId);
        if (!mounted) return;
        setState(() {
          _curatedBlocks = null;
          _useCurated = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AI 精选无可用正文，已还原原文')));
        }
        return;
      }
      await ref.read(dbProvider).saveCurated(_articleId, res.map((b) => b.toJson()).toList());
      if (!mounted) return;
      final summary = _curateSummary(_blocks, res);
      setState(() {
        _curatedBlocks = res;
        _useCurated = true;
      });
      _clearSelection();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary), duration: const Duration(seconds: 5)));
      }
    } catch (e) {
      if (mounted) {
        showDialog(context: context, builder: (c) => AlertDialog(title: const Text('AI 精选失败'), content: Text(errText(e)), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('确定'))]));
      }
    } finally {
      if (mounted) setState(() => _curating = false);
    }
  }

  Future<void> _removeCurated() async {
    if (_articleId == 0) return;
    await ref.read(dbProvider).clearCurated(_articleId);
    if (!mounted) return;
    setState(() {
      _curatedBlocks = null;
      _useCurated = false;
    });
    _clearSelection();
  }

  /// 对比精选前后的段落数与字数，生成「去除了多少」的结果摘要。
  String _curateSummary(List<ArticleBlock> before, List<ArticleBlock> after) {
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

  // ================= 图片 =================
  String _imgSrc(ArticleBlock b, int bi) {
    final src = b.src ?? '';
    if (src.isEmpty || src.startsWith('data:')) return src;
    final r = _imgRetry[bi];
    if (r == null) return src;
    return '$src${src.contains('?') ? '&' : '?'}_cb=$r';
  }

  void _onImgError(int bi) {
    setState(() {
      final r = _imgRetry[bi] ?? 0;
      if (r < 2) {
        _imgRetry[bi] = r + 1;
      } else {
        _imgErr.add(bi);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    return GoPage(
      topPad: false,
      child: Stack(
        children: [
          Column(
            children: [
              _appbar(),
              if (_selectMode)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
                  padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp3),
                  decoration: BoxDecoration(color: Go.onSurface.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(Go.rMd)),
                  child: const Text('点选多个单词组成选区，点「查询」出词卡 · 点「翻译」看译文 · 再次点词取消选中',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: Go.fsMeta, color: Go.bg, height: Go.lhSnug)),
                ),
              if (_showSettings) _settings(cfg),
              Expanded(child: _body()),
            ],
          ),
          ValueListenableBuilder<int>(
            valueListenable: _selVer,
            builder: (_, _, _) => (_selText.isNotEmpty || _selectedText.isNotEmpty) ? _selBar() : const SizedBox(),
          ),
          if (_ttsSynthesizing) _ttsMask(),
        ],
      ),
    );
  }

  Widget _appbar() {
    return GoAppBar(
      title: _title.isNotEmpty ? _title : '文章阅读',
      style: GoAppBarStyle.floating,
      leading: GoBack(onTap: () => Navigator.of(context).maybePop()),
      actions: [
        GoIconBtn(icon: 'menu', onTap: () => setState(() {
          _selectMode = !_selectMode;
          if (!_selectMode && _sel.isNotEmpty) {
            _sel.clear();
            _selVer.value++;
          }
        }), color: _selectMode ? Go.primary : null),
        GoIconBtn(icon: _ttsPlaying ? 'stop' : 'tts', onTap: _toggleReadAloud, color: _ttsPlaying ? Go.primary : null),
        GoIconBtn(icon: 'sparkle', onTap: _onCurateTap, color: _useCurated ? Go.primary : null),
        GoIconBtn(icon: 'settings', onTap: () => setState(() => _showSettings = !_showSettings), color: _showSettings ? Go.primary : null),
      ],
    );
  }

  Widget _settings(dynamic cfg) {
    return Container(
      decoration: const BoxDecoration(color: Go.surfaceRaised, border: Border(bottom: BorderSide(color: Go.outline, width: 0.5))),
      padding: const EdgeInsets.symmetric(vertical: Go.sp2),
      child: Column(
        children: [
          _setRow('字号', Row(mainAxisSize: MainAxisSize.min, children: [
            _step('A−', () => _changeFont(-1)),
            SizedBox(width: Go.r(80), child: Text('${cfg.fontSize.toStringAsFixed(0)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface3))),
            _step('A＋', () => _changeFont(1)),
          ])),
          _setRow('行距', Row(mainAxisSize: MainAxisSize.min, children: [
            _step('−', () => _changeLine(-0.1)),
            SizedBox(width: Go.r(80), child: Text(cfg.lineHeight.toStringAsFixed(1), textAlign: TextAlign.center, style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface3))),
            _step('＋', () => _changeLine(0.1)),
          ])),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp4),
            child: Align(alignment: Alignment.centerLeft, child: Text('单击查词 · 长按整句 · 工具栏「选择」可点选多词查询或翻译 · 朗读按钮可播放全文', style: TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3))),
          ),
        ],
      ),
    );
  }

  Widget _setRow(String label, Widget child) => Container(
        margin: const EdgeInsets.symmetric(horizontal: Go.sp6),
        padding: const EdgeInsets.symmetric(vertical: Go.sp4),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Go.outline, width: 0.5))),
        child: Row(
          children: [
            SizedBox(width: Go.r(96), child: Text(label, style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface))),
            const Spacer(),
            child,
          ],
        ),
      );

  Widget _step(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minWidth: Go.r(64)),
          height: Go.r(64),
          padding: const EdgeInsets.symmetric(horizontal: Go.sp2),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface)),
        ),
      );

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

  Widget _body() {
    if (_loading) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp6), Text('正文加载中…', style: TextStyle(color: Go.onSurface3, fontSize: Go.fsBodySm))]));
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error, style: const TextStyle(color: Go.danger)),
          const SizedBox(height: Go.sp3),
          GestureDetector(onTap: _load, child: const Text('重试', style: TextStyle(color: Go.primary, fontWeight: FontWeight.w600))),
        ]),
      );
    }
    // 正文未缓存（云端只缓存了元信息）：给占位块 + 打开原文。
    if (_plain.trim().isEmpty) return _noBody();
    return _reader();
  }

  /// 正文缺失时的占位：标题等元信息照常展示，正文区给说明与「打开原文」。
  Widget _noBody() {
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + Go.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cover(),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: Go.sp6),
            padding: const EdgeInsets.all(Go.sp6),
            decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rMd)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正文未缓存', style: TextStyle(fontSize: Go.fsH2, fontWeight: FontWeight.w600, color: Go.onSurface)),
                const SizedBox(height: Go.sp2),
                const Text('这篇文章暂时没有缓存正文，可以打开原文阅读，或稍后重新进入本页加载。',
                    style: TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface3, height: Go.lhRelaxed)),
                if (_sourceUrl.isNotEmpty) ...[
                  const SizedBox(height: Go.sp5),
                  GestureDetector(
                    onTap: _openOriginal,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp3),
                      decoration: BoxDecoration(color: Go.primary, borderRadius: BorderRadius.circular(Go.rFull)),
                      child: const Text('打开原文', style: TextStyle(fontSize: Go.fsBodySm, fontWeight: FontWeight.w600, color: Go.onPrimary)),
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

  Future<void> _openOriginal() async {
    final uri = Uri.tryParse(_sourceUrl.trim());
    if (uri == null || !uri.hasScheme) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('原文链接无效')));
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法打开原文，请稍后重试')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('打开原文失败，请稍后重试')));
    }
  }

  Widget _reader() {
    final cfg = ref.watch(appConfigProvider);
    final blocks = _activeBlocks;
    var paraIndex = -1;
    final widgets = <Widget>[];
    for (var bi = 0; bi < blocks.length; bi++) {
      final b = blocks[bi];
      if (b.type == 'p') {
        paraIndex++;
        widgets.add(_paragraph(b.text ?? '', paraIndex));
      } else if (b.type == 'img' && !_imgErr.contains(bi)) {
        widgets.add(_imageBlock(b, bi));
      }
    }
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + Go.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cover(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp6),
            child: DefaultTextStyle(
              style: TextStyle(fontSize: cfg.fontSize, height: cfg.lineHeight, color: Go.onSurface),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Go.sp12),
            child: Text('— 全文完 —', textAlign: TextAlign.center, style: TextStyle(color: Go.onSurface3, fontSize: Go.fsMeta, letterSpacing: 1)),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(String text, int pi) {
    _syncToks();
    final toks = pi < _paraToks.length ? _paraToks[pi] : const <_Tok>[];
    final starts = pi < _paraStarts.length ? _paraStarts[pi] : const <int>[];
    return Container(
      key: _paraKeys.putIfAbsent(pi, () => GlobalKey()),
      margin: const EdgeInsets.only(bottom: Go.sp5),
      child: GestureDetector(
        onLongPress: () => _onParaLongPress(pi),
        child: _ParaText(
          pi: pi,
          toks: toks,
          starts: starts,
          sel: _sel,
          selVer: _selVer,
          flashTok: _flashPara == pi ? _flashTok : -1,
          onTok: (ti, isLong) {
            final tk = ti < toks.length ? toks[ti] : const _Tok('', false);
            _onTok(tk, isLong, text, pi, ti);
          },
          onEmptyLongPress: () => _onParaLongPress(pi),
        ),
      ),
    );
  }

  void _onParaLongPress(int pi) {
    final paras = _paragraphs;
    if (pi >= paras.length) return;
    final para = paras[pi];
    if (para.trim().isEmpty) return;
    setState(() {
      _selText = para.trim().length > 400 ? para.trim().substring(0, 400) : para.trim();
    });
  }

  Widget _cover() {
    if (_title.isEmpty && _sourceHost.isEmpty) return const SizedBox.shrink();
    final toks = _tokenize(_title);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp6, Go.sp6, Go.sp5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_sourceHost.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Go.sp4),
              child: Text(_sourceHost.toUpperCase(), style: const TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: Go.primary)),
            ),
          Wrap(
            children: [
              for (var ti = 0; ti < toks.length; ti++)
                toks[ti].word
                    ? GestureDetector(
                        onTap: () => _onTok(toks[ti], false, _title, -1, ti, isTitle: true),
                        onLongPress: () => _onTok(toks[ti], true, _title, -1, ti, isTitle: true),
                        child: Text(toks[ti].text, style: const TextStyle(fontFamily: Go.fontRead, fontWeight: FontWeight.w700, fontSize: Go.fsDisplay, height: Go.lhTight, color: Go.onSurface)),
                      )
                    : Text(toks[ti].text, style: const TextStyle(fontFamily: Go.fontRead, fontWeight: FontWeight.w700, fontSize: Go.fsDisplay, height: Go.lhTight, color: Go.onSurface)),
            ],
          ),
          const SizedBox(height: Go.sp3),
          Wrap(
            spacing: Go.sp2,
            runSpacing: Go.sp2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_dateText, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
              if (_readMins > 0)
                Text('· $_readMins 分钟阅读', style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3)),
              if (_status == 'gone')
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Go.danger.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(Go.rFull)),
                  child: const Text('源已下线，显示本地缓存', style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: Go.danger)),
                ),
              if (_useCurated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Go.primary95, borderRadius: BorderRadius.circular(Go.rFull)),
                  child: const Text('AI 精选版', style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: Go.primary)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _imageBlock(ArticleBlock b, int bi) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Go.sp5),
      decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rMd)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Image.network(
            _imgSrc(b, bi),
            fit: BoxFit.fitWidth,
            errorBuilder: (_, _, _) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _onImgError(bi));
              return const SizedBox(height: 60);
            },
          ),
          if (b.alt != null && b.alt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Go.sp3, Go.sp2, Go.sp3, Go.sp3),
              child: Text(b.alt!, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3, height: 1.4)),
            ),
        ],
      ),
    );
  }

  Future<void> _saveSentence() async {
    final text = _selectedText.isNotEmpty ? _selectedText : _selText;
    if (text.trim().isEmpty) return;
    final a = _selAnchor();
    try {
      await ref.read(vocabProvider).saveSentence(text, _guid, _title, _sourceHost, a.pi, a.ti);
      ref.read(vocabRevisionProvider.notifier).bump();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已收藏句子')));
      _clearSelection();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收藏失败: $e')));
    }
  }

  /// 选区锚点 (pi, ti)：点选模式取最小 key 反解；长按整句用 _selPi/_selTi。
  ({int pi, int ti}) _selAnchor() {
    int pi = _selPi, ti = _selTi;
    if (_selectedText.isNotEmpty && _sel.isNotEmpty) {
      final k = _sel.reduce((a, b) => a < b ? a : b);
      pi = k >> 20;
      ti = k & 0xFFFFF;
    }
    return (pi: pi, ti: ti);
  }

  /// 入库的 sentence 字段：点选模式用锚点反解所在句；
  /// 长按路径的 `_selText` 本身就是整句/整段/标题，直接沿用，避免残留的锚点串段。
  String _selSentence(String fallback) {
    if (_sel.isEmpty) return fallback;
    final a = _selAnchor();
    if (a.pi >= 0 && a.pi < _paragraphs.length) {
      final s = _sentenceAround(_paragraphs[a.pi], a.ti);
      if (s.isNotEmpty) return s;
    }
    return fallback;
  }

  /// 划词「查询」：先记一次出现（单词与短语同一路径），再开词卡。
  Future<void> _querySelection() async {
    final text = _selectedText.isNotEmpty ? _selectedText : _selText;
    if (text.trim().isEmpty) return;
    final clean = ArticleScreen.cleanQueryText(text);
    final a = _selAnchor();
    final sentence = _selSentence(text);
    _clearSelection();
    if (clean.isEmpty) return;
    try {
      await ref.read(vocabProvider).recordOccurrence(clean, sentence, _guid, _title, _sourceHost, a.pi, a.ti);
      ref.read(vocabRevisionProvider.notifier).bump();
    } catch (_) {
      // 入库失败不阻断查词（本地写入，极少发生）。
    }
    if (!mounted) return;
    _openWord(text, sentence: sentence, paraIndex: a.pi, tokIndex: a.ti);
  }

  /// 划词「翻译」：单引擎走翻译网关，结果在底部弹层展示，可一键复制。
  void _translateSelection() {
    final text = _selectedText.isNotEmpty ? _selectedText : _selText;
    if (text.trim().isEmpty) return;
    _clearSelection();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => _TranslateSheet(text: text, onClose: () => Navigator.pop(c)),
    );
  }

  Widget _selBar() {
    final text = _selectedText.isNotEmpty ? _selectedText : _selText;
    final preview = text.length > 24 ? '${text.substring(0, 24)}…' : text;
    return Positioned(
      left: Go.sp4,
      right: Go.sp4,
      bottom: MediaQuery.of(context).padding.bottom + Go.sp4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
        decoration: BoxDecoration(color: const Color(0xFF2D2A35), borderRadius: BorderRadius.circular(Go.rLg), boxShadow: Go.shadow3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: Go.fsBodySm, height: Go.lhSnug)),
            const SizedBox(height: Go.sp3),
            // Wrap 而非 Row：系统字号放大时按钮换行，不会横向溢出（textScaler 回归铁律）。
            Wrap(
              spacing: Go.sp3,
              runSpacing: Go.sp2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _selBtn('朗读', onTap: _readSelection),
                _selBtn('查询', onTap: _querySelection),
                _selBtn('翻译', onTap: _translateSelection),
                _selBtn('收藏', onTap: _saveSentence),
                GestureDetector(onTap: _clearSelection, child: const Text('取消', style: TextStyle(color: Color(0xBFFFFFFF), fontSize: Go.fsBodySm))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _selBtn(String label, {required VoidCallback onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp5, vertical: Go.sp2),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: Go.fsBodySm)),
        ),
      );

  Widget _ttsMask() {
    return GestureDetector(
      onTap: () async {
        await ref.read(ttsProvider).stop();
        setState(() {
          _ttsSynthesizing = false;
          _ttsPlaying = false;
        });
      },
      child: Container(
        color: Colors.black.withValues(alpha: 0.32),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp10, vertical: Go.sp8),
          decoration: BoxDecoration(color: Go.surface, borderRadius: BorderRadius.circular(Go.rLg), boxShadow: Go.elev2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PolySpinner(),
              const SizedBox(height: Go.sp4),
              const Text('正在朗读…', style: TextStyle(fontSize: Go.fsBody, color: Go.onSurface)),
              const SizedBox(height: Go.sp4),
              GestureDetector(
                onTap: () async {
                  await ref.read(ttsProvider).stop();
                  setState(() {
                    _ttsSynthesizing = false;
                    _ttsPlaying = false;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp2),
                  decoration: BoxDecoration(border: Border.all(color: Go.primary), borderRadius: BorderRadius.circular(Go.rFull)),
                  child: const Text('取消', style: TextStyle(fontSize: Go.fsBodySm, color: Go.primary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单段正文：整段共用一个点击识别器，命中后用二分查找定位词，
/// 取代"每个词一个 WidgetSpan + GestureDetector"（实测 800 词 671ms → 约 40ms）；
/// 并且只有本段的选中集合发生变化时才重建，点一个词不再重建整篇。
class _ParaText extends StatefulWidget {
  final int pi;
  final List<_Tok> toks;
  final List<int> starts;
  final Set<int> sel;
  final ValueNotifier<int> selVer;
  final int flashTok;
  final void Function(int ti, bool isLong) onTok;
  final VoidCallback onEmptyLongPress;

  const _ParaText({
    required this.pi,
    required this.toks,
    required this.starts,
    required this.sel,
    required this.selVer,
    required this.flashTok,
    required this.onTok,
    required this.onEmptyLongPress,
  });

  @override
  State<_ParaText> createState() => _ParaTextState();
}

class _ParaTextState extends State<_ParaText> {
  final _rpKey = GlobalKey();
  Set<int> _mine = const {};
  late final TapGestureRecognizer _tap;
  static const _indent = TextSpan(text: '\u2003\u2003');

  @override
  void initState() {
    super.initState();
    _tap = TapGestureRecognizer()..onTapDown = (d) => _hit(d.globalPosition, false);
    widget.selVer.addListener(_onSelChanged);
    _mine = _slice();
  }

  @override
  void didUpdateWidget(covariant _ParaText old) {
    super.didUpdateWidget(old);
    if (old.selVer != widget.selVer) {
      old.selVer.removeListener(_onSelChanged);
      widget.selVer.addListener(_onSelChanged);
    }
    _mine = _slice();
  }

  void _onSelChanged() {
    final next = _slice();
    if (setEquals(next, _mine)) return;
    setState(() => _mine = next);
  }

  Set<int> _slice() {
    final out = <int>{};
    for (final k in widget.sel) {
      if ((k >> 20) == widget.pi) out.add(k & 0xFFFFF);
    }
    return out;
  }

  void _hit(Offset global, bool isLong) {
    final ro = _rpKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final pos = ro.getPositionForOffset(ro.globalToLocal(global));
    final ti = _tokenAt(pos.offset);
    final onWord = ti >= 0 && ti < widget.toks.length && widget.toks[ti].word;
    if (!onWord) {
      // 长按落在标点/空白上：保持旧行为，交给整段选择
      if (isLong) widget.onEmptyLongPress();
      return;
    }
    widget.onTok(ti, isLong);
  }

  /// 字符偏移 → token 下标：O(log n) 二分，取代按 token 逐个命中测试。
  int _tokenAt(int offset) {
    final starts = widget.starts;
    var lo = 0;
    var hi = starts.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  @override
  void dispose() {
    widget.selVer.removeListener(_onSelChanged);
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return GestureDetector(
      onLongPressStart: (d) => _hit(d.globalPosition, true),
      child: Text.rich(
        key: _rpKey,
        TextSpan(
          style: base,
          children: [
            _indent,
            for (var ti = 0; ti < widget.toks.length; ti++) _span(widget.toks[ti], ti),
          ],
        ),
      ),
    );
  }

  InlineSpan _span(_Tok tk, int ti) {
    final selected = _mine.contains(ti);
    final flash = widget.flashTok == ti;
    final style = (selected || flash)
        ? TextStyle(
            backgroundColor: Go.selWord,
            fontWeight: selected ? FontWeight.w600 : null,
            color: flash ? Go.primary : null,
          )
        : null;
    if (!tk.word) return TextSpan(text: tk.text, style: style);
    return TextSpan(text: tk.text, style: style, recognizer: _tap);
  }
}

/// 词卡：单词走 `wordProvider.lookup` 的结构化 JSON（kind=dict/text）；
/// 短语（查询文本含空格）直接走网关 AI 释义，不打 /dict。
/// 容器仍是 0.66 屏高的底部弹层，内容区滚动以容纳系统放大的文字。
class _WordCardDialog extends ConsumerStatefulWidget {
  final String word;
  final String sentence; // 词卡所在句（入库用）
  final String articleGuid;
  final String articleTitle;
  final String sourceLabel;
  final int paraIndex;
  final int tokIndex;
  final VoidCallback onClose;
  final void Function(String) onSpeak;
  const _WordCardDialog({
    required this.word,
    required this.sentence,
    required this.articleGuid,
    required this.articleTitle,
    required this.sourceLabel,
    required this.paraIndex,
    required this.tokIndex,
    required this.onClose,
    required this.onSpeak,
  });
  @override
  ConsumerState<_WordCardDialog> createState() => _WordCardDialogState();
}

class _WordCardDialogState extends ConsumerState<_WordCardDialog> {
  static final _reSpace = RegExp(r'\s');

  /// 短语查询的网关 prompt：第一行中文释义、第二行整条翻译，两行以内。
  static const _phraseSystem = '你是英语学习助手。解释用户给出的英文短语：'
      '第一行给这个短语的中文释义，第二行给整条短语的中文翻译。'
      '最多两行，不要标题、不要序号、不要英文解释、不要 Markdown。';

  String _mode = 'en2zh';
  late String _q; // 当前查询文本（词卡内点选建议词会替换）
  bool _loading = true;
  String _error = '';
  Map<String, dynamic>? _card; // kind == 'dict' 时的结构化词卡
  String _text = ''; // kind == 'text' / 短语 / 旧缓存裸文本
  bool _added = false;

  bool get _isPhrase => _q.trim().contains(_reSpace);

  @override
  void initState() {
    super.initState();
    _q = widget.word;
    _lookup();
  }

  Future<void> _lookup() async {
    setState(() {
      _loading = true;
      _error = '';
      _card = null;
      _text = '';
    });
    try {
      if (_isPhrase) {
        // 短语：不走 /dict，直接网关问 AI 要「中文释义 + 中文翻译」。
        final r = await ref.read(llmProvider).chat(_phraseSystem, '英文短语：$_q');
        if (!mounted) return;
        if (r.trim().isEmpty) {
          setState(() => _error = '未获取到释义，请重试');
        } else {
          setState(() => _text = r.trim());
        }
      } else {
        final raw = await ref.read(wordProvider).lookup(_q, mode: _mode);
        if (!mounted) return;
        if (raw.trim().isEmpty) {
          // 服务端失败冷却期内返回空串。
          setState(() => _error = '未获取到释义，请重试');
        } else {
          _applyResult(raw);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '查询失败：${errText(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 解析 `wordProvider.lookup` 的返回：
  /// `kind=dict` → 结构化词卡；`kind=text` → 纯文本译文；解析失败（旧缓存裸文本）→ 原样展示。
  void _applyResult(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        final kind = '${m['kind'] ?? ''}';
        if (kind == 'dict') {
          setState(() => _card = m);
          return;
        }
        if (kind == 'text') {
          final t = '${m['text'] ?? ''}'.trim();
          if (t.isEmpty) {
            setState(() => _error = '未获取到释义，请重试');
          } else {
            setState(() => _text = t);
          }
          return;
        }
      }
    } catch (_) {
      // 旧缓存里存的是裸文本：当纯文本卡片降级展示。
    }
    setState(() => _text = raw.trim());
  }

  /// 底部「加入生词库」：用当前阅读上下文记录出现位置，随后刷新词汇页。
  Future<void> _addToVocab() async {
    if (_added) return;
    try {
      await ref.read(vocabProvider).recordOccurrence(
          _q, widget.sentence, widget.articleGuid, widget.articleTitle, widget.sourceLabel, widget.paraIndex, widget.tokIndex);
      ref.read(vocabRevisionProvider.notifier).bump();
      if (!mounted) return;
      setState(() => _added = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已收录到生词库')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收录失败：${errText(e)}')));
    }
  }

  /// 点建议词重新查询（found:false 场景）。
  void _retryWith(String word) {
    final w = word.trim();
    if (w.isEmpty) return;
    setState(() => _q = w);
    _lookup();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.66,
      decoration: const BoxDecoration(color: Go.surfaceRaised, borderRadius: BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                Flexible(
                  child: Text(_q, style: const TextStyle(fontSize: Go.fsH1, fontWeight: FontWeight.w600, color: Go.onSurface)),
                ),
                if (_isPhrase) ...[
                  const SizedBox(width: Go.sp2),
                  _badge('短语'),
                ],
                const SizedBox(width: Go.sp2),
                _chip('朗读', true, () => widget.onSpeak(_q)),
                if (!_isPhrase) ...[
                  const SizedBox(width: Go.sp2),
                  _chip('中', _mode == 'en2zh', () {
                    if (_mode == 'en2zh') return;
                    setState(() => _mode = 'en2zh');
                    _lookup();
                  }),
                  const SizedBox(width: Go.sp2),
                  _chip('英', _mode == 'en2en', () {
                    if (_mode == 'en2en') return;
                    setState(() => _mode = 'en2en');
                    _lookup();
                  }),
                ],
                const SizedBox(width: Go.sp2),
                GestureDetector(onTap: widget.onClose, child: const Text('×', style: TextStyle(fontSize: 24, color: Go.onSurface3))),
              ],
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: Go.outline),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Go.sp6),
              child: _content(),
            ),
          ),
          if (_error.isEmpty) ...[
            const Divider(height: 0.5, thickness: 0.5, color: Go.outline),
            _addBar(),
          ],
        ],
      ),
    );
  }

  // ================= 渲染 =================
  Widget _content() {
    if (_loading) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('查询中…', style: TextStyle(color: Go.onSurface3))]));
    }
    if (_error.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_error, style: const TextStyle(color: Go.danger, fontSize: Go.fsBodySm)),
        const SizedBox(height: Go.sp3),
        GestureDetector(onTap: _lookup, child: const Text('重试', style: TextStyle(color: Go.primary, fontWeight: FontWeight.w600))),
      ]);
    }
    final card = _card;
    if (card != null) return _dictBody(card);
    // 纯文本卡片：kind=text 的整词翻译 / 短语 AI 释义 / 旧缓存裸文本。
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_isPhrase) ...[
        _sectionTitle('AI 释义'),
        const SizedBox(height: Go.sp2),
      ],
      Text(_text, style: const TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: Go.onSurface)),
    ]);
  }

  /// kind == 'dict'：音标/发音 + 中英释义 + 词形 + 考试标签 + 词频小字 + 建议词。
  Widget _dictBody(Map<String, dynamic> m) {
    final phonetic = '${m['phonetic'] ?? ''}'.trim();
    final senses = (m['senses'] as List? ?? const []).whereType<Map>().toList();
    final zh = '${m['zh'] ?? ''}'.trim();
    final ex = _exchangeText('${m['exchange'] ?? ''}'.trim());
    final tags = (m['tags'] as List? ?? const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    final meta = _dictMeta(m);
    final found = m['found'] != false;
    final suggestions = (m['suggestions'] as List? ?? const []).whereType<Map>().toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (phonetic.isNotEmpty)
            Text('/$phonetic/', style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface3, height: Go.lhNormal)),
          const SizedBox(width: Go.sp3),
          GestureDetector(
            onTap: () => widget.onSpeak(_q),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
              decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
              child: const Text('发音', style: TextStyle(fontSize: Go.fsMeta, color: Go.onSurface)),
            ),
          ),
        ]),
        const SizedBox(height: Go.sp5),
        if (senses.isNotEmpty) ...[
          _sectionTitle(_mode == 'en2en' ? '英文释义' : '中文释义'),
          const SizedBox(height: Go.sp3),
          for (final s in senses) _sense(s),
        ] else if (zh.isNotEmpty) ...[
          _sectionTitle(_mode == 'en2en' ? '英文释义' : '中文释义'),
          const SizedBox(height: Go.sp3),
          Text(zh, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: _mode == 'en2en' ? Go.onSurface2 : Go.onSurface)),
        ],
        if (senses.isNotEmpty || zh.isNotEmpty) const SizedBox(height: Go.sp5),
        if (ex.isNotEmpty) ...[
          _sectionTitle('词形'),
          const SizedBox(height: Go.sp2),
          Text(ex, style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface2, height: Go.lhNormal)),
          const SizedBox(height: Go.sp5),
        ],
        if (tags.isNotEmpty) ...[
          Wrap(spacing: Go.sp2, runSpacing: Go.sp2, children: [for (final t in tags) _badge(_tagLabel(t))]),
          const SizedBox(height: Go.sp5),
        ],
        if (meta.isNotEmpty) ...[
          Text(meta, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3, height: Go.lhNormal)),
          const SizedBox(height: Go.sp5),
        ],
        if (!found) ...[
          _sectionTitle(suggestions.isEmpty ? '词典里没有这个词' : '你是不是要找'),
          const SizedBox(height: Go.sp2),
          for (final s in suggestions) _suggestion(s),
        ],
      ],
    );
  }

  /// 单个义项：词性前缀 + 主释义（en2zh 用中文 definition，en2en 用英文 en），中文态下英文作小字。
  Widget _sense(Map s) {
    final pos = '${s['pos'] ?? ''}'.trim();
    final definition = '${s['definition'] ?? ''}'.trim();
    final en = '${s['en'] ?? ''}'.trim();
    final main = _mode == 'en2en' ? (en.isNotEmpty ? en : definition) : definition;
    final sub = _mode == 'en2en' ? '' : (en.isNotEmpty && en != definition ? en : '');
    if (main.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Go.sp3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (pos.isNotEmpty) ...[
            Text('$pos.', style: const TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: Go.primary, height: Go.lhNormal)),
            const SizedBox(width: Go.sp2),
          ],
          Expanded(child: Text(main, style: const TextStyle(fontSize: Go.fsBody, height: Go.lhNormal, color: Go.onSurface))),
        ]),
        if (sub.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Go.sp1),
            child: Text(sub, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3, height: Go.lhNormal)),
          ),
      ]),
    );
  }

  /// found == false 时的建议词，点击重新查询。
  Widget _suggestion(Map s) {
    final w = '${s['word'] ?? ''}'.trim();
    if (w.isEmpty) return const SizedBox.shrink();
    final ph = '${s['phonetic'] ?? ''}'.trim();
    final tr = '${s['translation'] ?? ''}'.trim();
    return GestureDetector(
      onTap: () => _retryWith(w),
      child: Container(
        margin: const EdgeInsets.only(bottom: Go.sp2),
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
        decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rMd)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(ph.isEmpty ? w : '$w  $ph', style: const TextStyle(fontSize: Go.fsBodySm, color: Go.onSurface, height: Go.lhNormal))),
          if (tr.isNotEmpty)
            Expanded(
              child: Text(tr, textAlign: TextAlign.right, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface3, height: Go.lhNormal)),
            ),
        ]),
      ),
    );
  }

  /// 柯林斯星级 / 牛津核心 / BNC 与词频排名（小字一行）。
  String _dictMeta(Map<String, dynamic> m) {
    final out = <String>[];
    final collins = (m['collins'] as num?)?.toInt() ?? 0;
    final oxford = (m['oxford'] as num?)?.toInt() ?? 0;
    final bnc = (m['bnc'] as num?)?.toInt() ?? 0;
    final frq = (m['frq'] as num?)?.toInt() ?? 0;
    if (collins > 0) out.add('柯林斯 $collins 星');
    if (oxford > 0) out.add('牛津核心');
    if (bnc > 0) out.add('BNC 常用 #$bnc');
    if (frq > 0) out.add('词频 #$frq');
    return out.join(' · ');
  }

  /// ECDICT exchange（`p:played d:played i:playing`）→ 可读词形串。
  static const _exLabels = <String, String>{
    '0': '原形',
    'b': '原形',
    'p': '过去式',
    'd': '过去分词',
    'i': '现在分词',
    '3': '第三人称单数',
    'r': '比较级',
    't': '最高级',
    's': '复数',
    'u': '不可数',
    'v': '动名词',
    'f': '缩写',
    'x': '过去式/过去分词',
    'y': '虚拟式',
  };

  String _exchangeText(String raw) {
    if (raw.isEmpty) return '';
    final parts = <String>[];
    for (final tok in raw.split(RegExp(r'[\s,]+'))) {
      final m = RegExp(r'^([A-Za-z0-9]+):(.+)$').firstMatch(tok);
      if (m == null) continue;
      final value = m.group(2)!.trim();
      if (value.isEmpty || value == '-') continue;
      final code = m.group(1)!.toLowerCase();
      parts.add('${_exLabels[code] ?? code} $value');
    }
    return parts.join(' · ');
  }

  static const _tagLabels = <String, String>{
    'zk': '中考',
    'gk': '高考',
    'ky': '考研',
    'cet4': '四级',
    'cet6': '六级',
    'toefl': '托福',
    'ielts': '雅思',
    'gre': 'GRE',
    'bec': 'BEC',
    'tem4': '专四',
    'tem8': '专八',
    'pte': 'PTE',
    'fce': 'FCE',
    'cae': 'CAE',
  };

  String _tagLabel(String t) {
    final hit = _tagLabels[t.toLowerCase()];
    if (hit != null) return hit;
    return t.length <= 4 ? t.toUpperCase() : t;
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: const TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: Go.onSurface3, letterSpacing: 0.4));

  Widget _badge(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp2, vertical: 1),
        decoration: BoxDecoration(color: Go.primary95, borderRadius: BorderRadius.circular(Go.rFull)),
        child: Text(label, style: const TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: Go.primary)),
      );

  /// 底部主按钮：加入生词库 → 已收录。
  Widget _addBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(Go.sp6, Go.sp4, Go.sp6, MediaQuery.of(context).padding.bottom + Go.sp5),
      child: GestureDetector(
        onTap: _added ? null : _addToVocab,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: Go.sp4),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _added ? Go.surface2 : Go.primary, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(_added ? '已收录' : '加入生词库',
              style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: _added ? Go.onSurface3 : Go.onPrimary)),
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
          decoration: BoxDecoration(color: on ? Go.primary : Colors.transparent, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: on ? Go.onPrimary : Go.onSurface3)),
        ),
      );
}

/// 划词「翻译」的底部弹层：网关翻译结果 + 复制。
class _TranslateSheet extends ConsumerStatefulWidget {
  final String text;
  final VoidCallback onClose;
  const _TranslateSheet({required this.text, required this.onClose});
  @override
  ConsumerState<_TranslateSheet> createState() => _TranslateSheetState();
}

class _TranslateSheetState extends ConsumerState<_TranslateSheet> {
  bool _loading = true;
  String _error = '';
  String _out = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = '';
      _out = '';
    });
    try {
      final r = await ref.read(translateProvider).translate(widget.text);
      if (!mounted) return;
      if (r.trim().isEmpty) {
        setState(() => _error = '翻译结果为空，请重试');
      } else {
        setState(() => _out = r.trim());
      }
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.45,
      decoration: const BoxDecoration(color: Go.surfaceRaised, borderRadius: BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                const Expanded(
                    child: Text('翻译', style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: Go.onSurface))),
                if (_out.isNotEmpty)
                  _sheetBtn('复制', () async {
                    await Clipboard.setData(ClipboardData(text: _out));
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制译文')));
                  }),
                const SizedBox(width: Go.sp3),
                GestureDetector(onTap: widget.onClose, child: const Text('×', style: TextStyle(fontSize: 24, color: Go.onSurface3))),
              ],
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: Go.outline),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Go.sp6),
              child: _loading
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('翻译中…', style: TextStyle(color: Go.onSurface3))]))
                  : _error.isNotEmpty
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_error, style: const TextStyle(color: Go.danger, fontSize: Go.fsBodySm)),
                          const SizedBox(height: Go.sp3),
                          GestureDetector(onTap: _run, child: const Text('重试', style: TextStyle(color: Go.primary, fontWeight: FontWeight.w600))),
                        ])
                      : Text(_out, style: const TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: Go.onSurface)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetBtn(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
          decoration: BoxDecoration(color: Go.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: const TextStyle(fontSize: Go.fsMeta, color: Go.onSurface)),
        ),
      );
}
