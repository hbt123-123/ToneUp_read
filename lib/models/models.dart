class ArticleBlock {
  final String type;
  final String? text;
  final String? src;
  final String? alt;
  ArticleBlock({required this.type, this.text, this.src, this.alt});
  factory ArticleBlock.fromJson(Map<String, dynamic> j) =>
      ArticleBlock(type: j['type'] as String, text: j['text'] as String?, src: j['src'] as String?, alt: j['alt'] as String?);
  Map<String, dynamic> toJson() => {'type': type, if (text != null) 'text': text, if (src != null) 'src': src, if (alt != null) 'alt': alt};
}
