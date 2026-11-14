import 'package:toneup_read/models/models.dart';

/// 正文 token：`word == true` 才可点词/朗读命中。
class ReadingToken {
  final String text;
  final bool word;
  const ReadingToken(this.text, this.word);
}

/// 一句朗读单元：文本 + 在原文里的位置（段落下标 + token 闭区间）。
/// 高亮时不重新分句，直接用 [tiStart]..[tiEnd] 给 token 上色。
class TtsSegment {
  final String text;
  final int pi;
  final int tiStart;
  final int tiEnd; // 含
  const TtsSegment(this.text, this.pi, this.tiStart, this.tiEnd);
}

/// 阅读器一次加载的正文快照 + 派生展示值。
///
/// 只放「一篇文章是什么」；选区、朗读、图片重试这类交互状态在
/// `ReadingController` 里，避免把瞬时状态混进数据模型。
class ReadingState {
  int articleId;
  List<ArticleBlock> blocks;
  List<ArticleBlock>? curatedBlocks;
  bool useCurated;
  String plain;
  String title;
  String guid;
  String sourceUrl;
  String source; // 云端来源名（articles.source），优先于 sourceUrl 的 host
  String status; // 'gone' 表示源已下线，仅显示本地缓存
  int? publishedAt; // 毫秒时间戳
  int? cachedAt; // 毫秒时间戳
  int wordCount;
  bool loading;
  String error;

  ReadingState({
    required this.guid,
    required this.title,
    required this.articleId,
    this.blocks = const [],
    this.curatedBlocks,
    this.useCurated = false,
    this.plain = '',
    this.sourceUrl = '',
    this.source = '',
    this.status = '',
    this.publishedAt,
    this.cachedAt,
    this.wordCount = 0,
    this.loading = true,
    this.error = '',
  });

  List<ArticleBlock> get activeBlocks =>
      (useCurated && curatedBlocks != null) ? curatedBlocks! : blocks;

  /// 只取段落块，下标与正文里的段落顺序一致。
  List<String> get paragraphs =>
      activeBlocks.where((b) => b.type == 'p').map((b) => b.text ?? '').toList();

  /// 页头来源：优先云端 `source`，其次 sourceUrl 的 host（去掉 www），兜底「收录文章」。
  String get sourceHost {
    final s = source.trim();
    if (s.isNotEmpty) return s;
    if (sourceUrl.isEmpty) return '收录文章';
    try {
      final host = Uri.parse(sourceUrl).host.replaceFirst(RegExp(r'^www\.'), '');
      return host.isEmpty ? '收录文章' : host;
    } catch (_) {
      return '收录文章';
    }
  }

  /// 日期：publishedAt 优先，其次 cachedAt（均为毫秒时间戳，本地时区 MM-dd）；都没有则「—」。
  String get dateText {
    final ts = publishedAt ?? cachedAt;
    if (ts == null || ts <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '$mm-$dd';
  }

  int get readMins => wordCount > 0 ? (wordCount / 60).round().clamp(1, 9999) : 0;
}
