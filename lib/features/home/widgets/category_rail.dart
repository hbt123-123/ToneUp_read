import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';

/// 分类（主题）词条：云端 `ai_verdict.topics` 的英文标签 → 中文分类。
/// 接口不返回完整词表，这里按常见词宽松映射（精确相等或 topic 包含词条），
/// 映射不到的标签不归入任何分类。
class CategoryEntry {
  final String key;
  final String label;
  final List<String> tags;
  const CategoryEntry(this.key, this.label, this.tags);
}

const List<CategoryEntry> kCategories = [
  CategoryEntry('tech', '科技', ['technology', 'tech', 'ai', 'artificial intelligence', 'machine learning']),
  CategoryEntry('business', '商业', ['business', 'economy', 'economics', 'finance', 'money', 'work', 'jobs']),
  CategoryEntry('culture', '文化', ['culture', 'arts', 'art', 'entertainment', 'media', 'lifestyle']),
  CategoryEntry('science', '科学', ['science', 'space', 'research', 'physics', 'biology']),
  CategoryEntry('society', '社会', ['society', 'politics', 'political', 'world', 'law', 'education']),
  CategoryEntry('health', '健康', ['health', 'medicine', 'medical', 'wellness']),
  CategoryEntry('environment', '环境', ['environment', 'climate', 'energy', 'nature']),
];

/// 文章 topics → 命中的分类 key 列表（一篇可属多类）。
///
/// 词级匹配：topic 先整串与词条精确比对（如 "mental health"），
/// 再按非字母数字切词逐词比对——词等于词条，或（词条 ≥4 字符时）以词条为前缀
/// （technologies → tech）。整串 contains 会误伤
/// （'artificial intelligence' 撞 'art'、'network' 撞 'work'），这里必须按词。
List<String> categoriesOfTopics(List<String> topics) {
  if (topics.isEmpty) return const [];
  final out = <String>{};
  for (final raw in topics) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) continue;
    for (final c in kCategories) {
      if (c.tags.contains(t)) out.add(c.key);
    }
    for (final w in t.split(RegExp(r'[^a-z0-9]+'))) {
      if (w.isEmpty) continue;
      for (final c in kCategories) {
        for (final tag in c.tags) {
          if (w == tag || (tag.length >= 4 && w.startsWith(tag))) out.add(c.key);
        }
      }
    }
  }
  return out.toList();
}

/// 分类筛选条：「全部」+ [kCategories] 中文 chips（横向滚动）。
class HomeCategoryRail extends StatelessWidget {
  final String? selected; // null = 全部
  final ValueChanged<String?> onPick;

  const HomeCategoryRail({super.key, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip(context, '全部', selected == null, () => onPick(null)),
          for (final c in kCategories) ...[
            const SizedBox(width: Go.sp2),
            _chip(context, c.label, selected == c.key, () => onPick(c.key)),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, bool on, VoidCallback onTap) {
    final g = GoPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp2),
        decoration: BoxDecoration(
          color: on ? g.primary : g.glassBg,
          borderRadius: BorderRadius.circular(Go.rFull),
          border: on ? null : Border.all(color: g.glassBorder, width: 0.5),
          boxShadow: g.elev1,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: Go.fsBodySm,
            fontWeight: FontWeight.w600,
            color: on ? g.onPrimary : g.onSurface2,
          ),
        ),
      ),
    );
  }
}
