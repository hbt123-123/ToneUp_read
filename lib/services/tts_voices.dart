// Edge TTS 内置音色表。
//
// 与 `tts_service.dart` 的分工：这里只描述「有哪些音色」以及「用户存的 id 是否
// 还合法」，不做任何网络请求。设置页与阅读页共用这份表，保证 UI 顺序稳定。

/// 兜底音色。用户没选过、或存的 id 已下线时用它。
const String kEdgeDefaultVoice = 'en-US-AriaNeural';

/// `[id, 中文标签]`，**顺序即 UI 顺序**，不要随意重排。
///
/// 英文名保留 Edge 原始拼写（`en-US-AriaNeural`），发音人名字放进中文标签里，
/// 这样即使 Voice 名字变化，用户在列表里看到的仍是熟悉的「Aria」。
const List<List<String>> kEdgeVoices = <List<String>>[
  <String>['en-US-AriaNeural', 'Aria · 自然女声（美）'],
  <String>['en-US-JennyNeural', 'Jenny · 亲切女声（美）'],
  <String>['en-US-EmmaMultilingualNeural', 'Emma · 清晰女声（美）'],
  <String>['en-US-GuyNeural', 'Guy · 沉稳男声（美）'],
  <String>['en-US-DavisNeural', 'Davis · 磁性男声（美）'],
  <String>['en-GB-SoniaNeural', 'Sonia · 英式女声'],
  <String>['en-GB-RyanNeural', 'Ryan · 英式男声'],
  <String>['en-AU-NatashaNeural', 'Natasha · 澳式女声'],
];

/// 这个 id 是不是我们提供的音色之一（不做 trim，调用方先自行归一）。
bool isKnownEdgeVoice(String id) {
  for (final v in kEdgeVoices) {
    if (v.isNotEmpty && v.first == id) return true;
  }
  return false;
}

/// 把任意来源的音色 id 归一成合法值：空串/未知（例如旧版的网关音色名）
/// 一律回落到 [kEdgeDefaultVoice]。
String normalizeEdgeVoice(String? id) {
  final v = (id ?? '').trim();
  if (v.isEmpty || !isKnownEdgeVoice(v)) return kEdgeDefaultVoice;
  return v;
}
