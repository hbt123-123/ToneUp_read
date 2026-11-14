// 阅读正文字体选项表（与 tts_voices.dart 同构：这里只描述有哪些选项、
// 用户存的 id 是否合法，不涉及任何渲染细节）。

/// 兜底字体：空串 = 系统默认（无衬线）。
const String kReaderDefaultFont = '';

/// `[id, 中文标签]`，**顺序即 UI 顺序**，不要随意重排。
/// `serif` / `monospace` 是 Android 通用字体族（分别落到 Noto Serif / Roboto
/// Mono），零依赖、零包体积、离线可用。
const List<List<String>> kReaderFonts = <List<String>>[
  <String>[kReaderDefaultFont, '默认'],
  <String>['serif', '衬线'],
  <String>['monospace', '等宽'],
];

/// 这个 id 是不是我们提供的字体之一（不做 trim，调用方先自行归一）。
bool isKnownReaderFont(String id) {
  for (final f in kReaderFonts) {
    if (f.isNotEmpty && f.first == id) return true;
  }
  return false;
}

/// 把任意来源的字体 id 归一成合法值：空串/未知一律回落 [kReaderDefaultFont]。
String normalizeReaderFont(String? id) {
  final v = (id ?? '').trim();
  if (v.isEmpty || !isKnownReaderFont(v)) return kReaderDefaultFont;
  return v;
}
