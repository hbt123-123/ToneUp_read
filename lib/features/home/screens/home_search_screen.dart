import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/home/widgets/article_card.dart';
import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 文章搜索页：按标题/摘要检索本地库（列表接口的元信息都已 UPSERT 落库），
/// 离线可用；300ms 防抖，命中上限 50 条。点结果与首页同流程打开（缓存正文 → 阅读器）。
class HomeSearchScreen extends ConsumerStatefulWidget {
  const HomeSearchScreen({super.key});
  @override
  ConsumerState<HomeSearchScreen> createState() => _HomeSearchScreenState();
}

class _HomeSearchScreenState extends ConsumerState<HomeSearchScreen> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  final List<Map<String, dynamic>> _items = [];
  final Map<String, String> _zh = {};
  final Set<String> _cached = {};
  bool _searching = false;
  bool _opening = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String q) async {
    final t = q.trim();
    _query = t;
    if (t.isEmpty) {
      setState(() {
        _items.clear();
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await ref.read(remoteArticleProvider).searchArticles(t);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(rows.map(_rowToItem));
        _searching = false;
      });
      _fillZh(rows);
      _refreshCached();
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('搜索失败：${_errOf(e)}')));
    }
  }

  /// 批量取中文标题：失败静默，卡片回落英文标题。
  Future<void> _fillZh(List<Map<String, dynamic>> rows) async {
    final titles = <String>{};
    for (final it in rows) {
      final t = '${it['title'] ?? ''}'.trim();
      if (t.isNotEmpty) titles.add(t);
    }
    if (titles.isEmpty) return;
    try {
      final m = await ref.read(remoteArticleProvider).titleZhBatch(titles.toList());
      if (!mounted || m.isEmpty) return;
      setState(() => _zh.addAll(m));
    } catch (_) {}
  }

  Future<void> _refreshCached() async {
    try {
      final set = await ref.read(remoteArticleProvider).cachedGuids();
      if (!mounted) return;
      setState(() {
        _cached
          ..clear()
          ..addAll(set);
      });
    } catch (_) {}
  }

  /// DB 行 → 卡片同构 map（snake_case，与首页 `_fromRow` 一致）。
  Map<String, dynamic> _rowToItem(Map<String, dynamic> r) => <String, dynamic>{
        'id': r['remoteId'],
        'localId': r['id'],
        'title': r['title'],
        'source': r['source'],
        'url': '${r['sourceUrl'] ?? r['guid'] ?? ''}',
        'word_count': r['wordCount'],
        'published_at': r['publishedAt'],
      };

  /// 与首页 `_openItem` 同流程：缓存正文 → bump → 阅读器。
  Future<void> _openItem(Map<String, dynamic> it) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final remoteId = it['id'] is num ? (it['id'] as num).toInt() : null;
      final localId = it['localId'] is num ? (it['localId'] as num).toInt() : null;
      int? id;
      if (remoteId != null) {
        id = await ref.read(remoteArticleProvider).cacheArticle(remoteId);
      } else {
        // 离线/已下线行没有远端 id：直接开本地副本。
        id = localId;
      }
      if (id == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该文章已从源站下线')));
        }
        return;
      }
      if (!mounted) return;
      final target = id;
      ref.read(articleRevisionProvider.notifier).bump();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ArticleScreen(articleId: target, title: '${it['title'] ?? ''}'.trim()),
        ),
      );
      await _search(_input.text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开失败：${_errOf(e)}')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// 面向用户的错误文案：AppException 自带中文 message，其它回落通用提示。
  String _errOf(Object e) => e is AppException ? e.message : '加载失败，请稍后重试';

  @override
  Widget build(BuildContext context) {
    return GoPage(
      topPad: false,
      child: Column(
        children: [
          _header(context),
          Expanded(child: _results(context)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(Go.sp4, top + Go.sp2, Go.sp4, Go.sp3),
      child: Row(
        children: [
          GoBack(onTap: () => Navigator.of(context).maybePop()),
          const SizedBox(width: Go.sp3),
          Expanded(
            child: GoField(
              controller: _input,
              hint: '搜索标题 / 主题',
              onChanged: _onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    if (_searching) return _skeletonList();
    if (_query.isEmpty) {
      return Center(child: GoEmpty(icon: 'search', title: '搜索文章', desc: '按标题或主题关键词检索已收录的文章'));
    }
    if (_items.isEmpty) {
      return Center(child: GoEmpty(icon: 'search', title: '没有找到相关文章', desc: '换个关键词试试'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, MediaQuery.of(context).padding.bottom + Go.sp16),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final it = _items[i];
        final en = '${it['title'] ?? ''}'.trim();
        final url = '${it['url'] ?? ''}';
        return HomeArticleCard(
          item: it,
          zhTitle: en.isEmpty ? null : _zh[en],
          cached: url.isNotEmpty && _cached.contains(url),
          onTap: () => _openItem(it),
        );
      },
    );
  }

  Widget _skeletonList() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp16),
      children: [for (var i = 0; i < 4; i++) _skeletonCard()],
    );
  }

  Widget _skeletonCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: Go.sp3),
      child: GoCard(
        blur: false,
        padding: const EdgeInsets.all(Go.sp5),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GoSkeleton(height: 16),
            SizedBox(height: Go.sp3),
            GoSkeleton(width: 220, height: 12),
          ],
        ),
      ),
    );
  }
}
