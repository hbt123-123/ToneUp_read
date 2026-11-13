import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 词卡：单词走 `wordProvider.lookup` 的结构化 JSON（kind=dict/text）；
/// 短语（查询文本含空格）直接走网关 AI 释义，不打 /dict。
/// 容器仍是 0.66 屏高的底部弹层，内容区滚动以容纳系统放大的文字。
class WordCardSheet extends ConsumerStatefulWidget {
  final String word;
  final String sentence; // 词卡所在句（入库用）
  final String articleGuid;
  final String articleTitle;
  final String sourceLabel;
  final int paraIndex;
  final int tokIndex;
  final VoidCallback onClose;
  final void Function(String) onSpeak;
  const WordCardSheet({
    super.key,
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
  ConsumerState<WordCardSheet> createState() => _WordCardSheetState();
}

class _WordCardSheetState extends ConsumerState<WordCardSheet> {
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
    final g = GoPalette.of(context);
    return Container(
      height: MediaQuery.of(context).size.height * 0.66,
      decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                Flexible(
                  child: Text(_q, style: TextStyle(fontSize: Go.fsH1, fontWeight: FontWeight.w600, color: g.onSurface)),
                ),
                if (_isPhrase) ...[
                  const SizedBox(width: Go.sp2),
                  _badge(g, '短语'),
                ],
                const SizedBox(width: Go.sp2),
                _chip(g, '朗读', true, () => widget.onSpeak(_q)),
                if (!_isPhrase) ...[
                  const SizedBox(width: Go.sp2),
                  _chip(g, '中', _mode == 'en2zh', () {
                    if (_mode == 'en2zh') return;
                    setState(() => _mode = 'en2zh');
                    _lookup();
                  }),
                  const SizedBox(width: Go.sp2),
                  _chip(g, '英', _mode == 'en2en', () {
                    if (_mode == 'en2en') return;
                    setState(() => _mode = 'en2en');
                    _lookup();
                  }),
                ],
                const SizedBox(width: Go.sp2),
                GestureDetector(onTap: widget.onClose, child: Text('×', style: TextStyle(fontSize: 24, color: g.onSurface3))),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: g.outline),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Go.sp6),
              child: _content(g),
            ),
          ),
          if (_error.isEmpty) ...[
            Divider(height: 0.5, thickness: 0.5, color: g.outline),
            _addBar(g),
          ],
        ],
      ),
    );
  }

  // ================= 渲染 =================
  Widget _content(GoPalette g) {
    if (_loading) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('查询中…', style: TextStyle(color: g.onSurface3))]));
    }
    if (_error.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_error, style: TextStyle(color: g.danger, fontSize: Go.fsBodySm)),
        const SizedBox(height: Go.sp3),
        GestureDetector(onTap: _lookup, child: Text('重试', style: TextStyle(color: g.primary, fontWeight: FontWeight.w600))),
      ]);
    }
    final card = _card;
    if (card != null) return _dictBody(g, card);
    // 纯文本卡片：kind=text 的整词翻译 / 短语 AI 释义 / 旧缓存裸文本。
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_isPhrase) ...[
        _sectionTitle(g, 'AI 释义'),
        const SizedBox(height: Go.sp2),
      ],
      Text(_text, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: g.onSurface)),
    ]);
  }

  /// kind == 'dict'：音标/发音 + 中英释义 + 词形 + 考试标签 + 词频小字 + 建议词。
  Widget _dictBody(GoPalette g, Map<String, dynamic> m) {
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
            Text('/$phonetic/', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface3, height: Go.lhNormal)),
          const SizedBox(width: Go.sp3),
          GestureDetector(
            onTap: () => widget.onSpeak(_q),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
              decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
              child: Text('发音', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface)),
            ),
          ),
        ]),
        const SizedBox(height: Go.sp5),
        if (senses.isNotEmpty) ...[
          _sectionTitle(g, _mode == 'en2en' ? '英文释义' : '中文释义'),
          const SizedBox(height: Go.sp3),
          for (final s in senses) _sense(g, s),
        ] else if (zh.isNotEmpty) ...[
          _sectionTitle(g, _mode == 'en2en' ? '英文释义' : '中文释义'),
          const SizedBox(height: Go.sp3),
          Text(zh, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: _mode == 'en2en' ? g.onSurface2 : g.onSurface)),
        ],
        if (senses.isNotEmpty || zh.isNotEmpty) const SizedBox(height: Go.sp5),
        if (ex.isNotEmpty) ...[
          _sectionTitle(g, '词形'),
          const SizedBox(height: Go.sp2),
          Text(ex, style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface2, height: Go.lhNormal)),
          const SizedBox(height: Go.sp5),
        ],
        if (tags.isNotEmpty) ...[
          Wrap(spacing: Go.sp2, runSpacing: Go.sp2, children: [for (final t in tags) _badge(g, _tagLabel(t))]),
          const SizedBox(height: Go.sp5),
        ],
        if (meta.isNotEmpty) ...[
          Text(meta, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3, height: Go.lhNormal)),
          const SizedBox(height: Go.sp5),
        ],
        if (!found) ...[
          _sectionTitle(g, suggestions.isEmpty ? '词典里没有这个词' : '你是不是要找'),
          const SizedBox(height: Go.sp2),
          for (final s in suggestions) _suggestion(g, s),
        ],
      ],
    );
  }

  /// 单个义项：词性前缀 + 主释义（en2zh 用中文 definition，en2en 用英文 en），中文态下英文作小字。
  Widget _sense(GoPalette g, Map s) {
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
            Text('$pos.', style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: g.primary, height: Go.lhNormal)),
            const SizedBox(width: Go.sp2),
          ],
          Expanded(child: Text(main, style: TextStyle(fontSize: Go.fsBody, height: Go.lhNormal, color: g.onSurface))),
        ]),
        if (sub.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Go.sp1),
            child: Text(sub, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3, height: Go.lhNormal)),
          ),
      ]),
    );
  }

  /// found == false 时的建议词，点击重新查询。
  Widget _suggestion(GoPalette g, Map s) {
    final w = '${s['word'] ?? ''}'.trim();
    if (w.isEmpty) return const SizedBox.shrink();
    final ph = '${s['phonetic'] ?? ''}'.trim();
    final tr = '${s['translation'] ?? ''}'.trim();
    return GestureDetector(
      onTap: () => _retryWith(w),
      child: Container(
        margin: const EdgeInsets.only(bottom: Go.sp2),
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
        decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rMd)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(ph.isEmpty ? w : '$w  $ph', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface, height: Go.lhNormal))),
          if (tr.isNotEmpty)
            Expanded(
              child: Text(tr, textAlign: TextAlign.right, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3, height: Go.lhNormal)),
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

  Widget _sectionTitle(GoPalette g, String t) =>
      Text(t, style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: g.onSurface3, letterSpacing: 0.4));

  Widget _badge(GoPalette g, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp2, vertical: 1),
        decoration: BoxDecoration(color: g.primary95, borderRadius: BorderRadius.circular(Go.rFull)),
        child: Text(label, style: TextStyle(fontSize: Go.fsCap, fontWeight: FontWeight.w600, color: g.primary)),
      );

  /// 底部主按钮：加入生词库 → 已收录。
  Widget _addBar(GoPalette g) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Go.sp6, Go.sp4, Go.sp6, MediaQuery.of(context).padding.bottom + Go.sp5),
      child: GestureDetector(
        onTap: _added ? null : _addToVocab,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: Go.sp4),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _added ? g.surface2 : g.primary, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(_added ? '已收录' : '加入生词库',
              style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: _added ? g.onSurface3 : g.onPrimary)),
        ),
      ),
    );
  }

  Widget _chip(GoPalette g, String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: Go.sp1),
          decoration: BoxDecoration(color: on ? g.primary : Colors.transparent, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: on ? g.onPrimary : g.onSurface3)),
        ),
      );
}
