import 'dart:convert';

/// `wordProvider.lookup` 返回值的统一解析，词卡完整弹层（word_popup.dart）与
/// 就地浮窗（word_popover.dart）共用，避免两处各写一份 jsonDecode 分支。
///
/// - `kind=dict`：/dict 的结构化词卡；
/// - `kind=text`：整词翻译回落（`{"kind":"text","text":...}`）；
/// - 解析失败（旧缓存里存的裸文本）：整体按纯文本展示。
class ParsedLookup {
  /// kind == 'dict' 时的结构化词卡（word/found/phonetic/zh/senses/…），否则 null。
  final Map<String, dynamic>? card;

  /// 纯文本结果（kind=text / 短语 AI 释义 / 旧缓存裸文本）。
  final String text;

  const ParsedLookup({this.card, this.text = ''});

  /// 结构化词卡且词典未收录该词（found:false，带 suggestions）。
  bool get notFound => card != null && card!['found'] == false;
}

ParsedLookup parseLookup(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is Map) {
      final m = Map<String, dynamic>.from(v);
      final kind = '${m['kind'] ?? ''}';
      if (kind == 'dict') return ParsedLookup(card: m);
      if (kind == 'text') return ParsedLookup(text: '${m['text'] ?? ''}'.trim());
    }
  } catch (_) {
    // 旧缓存里存的是裸文本：当纯文本卡片降级展示。
  }
  return ParsedLookup(text: raw.trim());
}
