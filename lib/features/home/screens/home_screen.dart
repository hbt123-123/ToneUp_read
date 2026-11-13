import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/home/widgets/article_card.dart';
import 'package:toneup_read/features/home/widgets/home_notice.dart';
import 'package:toneup_read/features/home/widgets/source_rail.dart';
import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 首页（时文阅读）：云端文章列表卡片流。
///
/// - 列表走 `remoteArticleProvider.list`（page/perPage=20 分页 + source 筛选），
///   拉到后批量取中文标题（`titleZhBatch`），卡片显示 `zh ?? title`。
/// - 点卡片先 `cacheArticle(remoteId)` 落正文，成功后开阅读器并 `articleRevisionProvider.bump()`。
/// - 列表请求失败走 `cachedArticles()` 离线兜底 + 顶部横幅；下拉刷新重拉 page=1。
/// - 文字一律只给 `maxLines`/`overflow`，不套固定高度（textScaler 回归铁律）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const int _perPage = 20;
  /// 距底部还剩多少像素时自动续页。
  static const double _loadMoreThreshold = 300;

  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scroll = ScrollController();

  /// 已缓存正文的 guid（= url）集合，卡片右上「已缓存」小标。
  final Set<String> _cached = {};

  /// 英文标题 → 中文标题。
  final Map<String, String> _zh = {};

  /// 由累计 items 汇总的来源（不含「全部」），只增不清，避免切走后回不来。
  final List<String> _sources = [];

  String? _source; // null = 全部
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _opening = false;
  bool _offline = false;
  bool _noKey = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirst());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _hasMore => !_offline && !_noKey && _items.length < _total;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // 内容没撑满视口时不自动续页（靠底部「加载更多」按钮），否则首屏会连环翻页。
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - _loadMoreThreshold) _loadMore();
  }

  // =====================================================================
  // 数据
  // =====================================================================

  Future<void> _loadFirst() async {
    if (!mounted) return;
    final cfg = ref.read(appConfigProvider);
    if (cfg.articleApiKey.trim().isEmpty) {
      // 未配置密钥：不发网络请求，给引导横幅 + 本地缓存兜底。
      setState(() {
        _loading = false;
        _noKey = true;
        _offline = false;
        _error = '';
        _page = 1;
        _total = 0;
      });
      await _loadCached();
      return;
    }
    setState(() {
      _loading = true;
      _noKey = false;
      _error = '';
    });
    try {
      final res =
          await ref.read(remoteArticleProvider).list(source: _source, page: 1, perPage: _perPage);
      final rows = _parseItems(res);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(rows);
        _page = 1;
        _total = _parseTotal(res, rows.length);
        _offline = false;
        _error = '';
        _loading = false;
        _collectSources(rows);
      });
      await _fillZh(rows);
      await _refreshCached();
    } catch (e) {
      // 列表失败 → 离线兜底：本地已缓存的行。
      var cached = const <Map<String, dynamic>>[];
      try {
        cached = await ref.read(remoteArticleProvider).cachedArticles(source: _source);
      } catch (_) {
        cached = const [];
      }
      if (!mounted) return;
      final offlineRows = cached.map(_fromRow).toList();
      setState(() {
        _loading = false;
        if (offlineRows.isNotEmpty) {
          _offline = true;
          _error = '';
          _items
            ..clear()
            ..addAll(offlineRows);
          _page = 1;
          _total = offlineRows.length;
          _collectSources(offlineRows);
        } else {
          _offline = false;
          _error = _errOf(e);
        }
      });
      if (offlineRows.isNotEmpty) {
        await _fillZh(offlineRows);
        await _refreshCached();
      }
    }
  }

  /// 未配置密钥时的本地缓存兜底（不打网络，`titleZhBatch` 只回读 title_zh 表）。
  Future<void> _loadCached() async {
    var rows = const <Map<String, dynamic>>[];
    try {
      rows = await ref.read(remoteArticleProvider).cachedArticles();
    } catch (_) {
      rows = const [];
    }
    if (!mounted) return;
    final mapped = rows.map(_fromRow).toList();
    setState(() {
      _items
        ..clear()
        ..addAll(mapped);
      _total = mapped.length;
      _collectSources(mapped);
    });
    await _fillZh(mapped);
    await _refreshCached();
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _offline || _noKey) return;
    if (_items.isEmpty || _items.length >= _total) return;
    final next = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final res = await ref
          .read(remoteArticleProvider)
          .list(source: _source, page: next, perPage: _perPage);
      final rows = _parseItems(res);
      if (!mounted) return;
      setState(() {
        final seen = _items
            .map((e) => '${e['url'] ?? ''}')
            .where((u) => u.isNotEmpty)
            .toSet();
        for (final r in rows) {
          final u = '${r['url'] ?? ''}';
          if (u.isNotEmpty && seen.contains(u)) continue;
          if (u.isNotEmpty) seen.add(u);
          _items.add(r);
        }
        _page = next;
        _total = _parseTotal(res, _total);
        _loadingMore = false;
        _collectSources(rows);
      });
      await _fillZh(rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载更多失败：${_errOf(e)}')));
    }
  }

  Future<void> _pickSource(String? s) async {
    if (_source == s) return;
    setState(() {
      _source = s;
      _items.clear();
      _page = 1;
      _total = 0;
      _loading = true;
      _error = '';
      _offline = false;
    });
    await _loadFirst();
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
    } catch (_) {
      // 缓存标记刷新失败不影响列表展示。
    }
  }

  /// 批量取中文标题：失败由 `titleZhBatch` 内部吞掉，卡片回落英文标题。
  Future<void> _fillZh(List<Map<String, dynamic>> rows) async {
    final titles = <String>{};
    for (final it in rows) {
      final t = (it['title'] ?? '').toString().trim();
      if (t.isNotEmpty) titles.add(t);
    }
    if (titles.isEmpty) return;
    try {
      final m = await ref.read(remoteArticleProvider).titleZhBatch(titles.toList());
      if (!mounted || m.isEmpty) return;
      setState(() => _zh.addAll(m));
    } catch (_) {}
  }

  void _collectSources(List<Map<String, dynamic>> rows) {
    for (final it in rows) {
      final s = (it['source'] ?? '').toString().trim();
      if (s.isEmpty || _sources.contains(s)) continue;
      _sources.add(s);
    }
  }

  List<Map<String, dynamic>> _parseItems(Map res) {
    final raw = res['items'];
    if (raw is! List) return const [];
    return [
      for (final it in raw)
        if (it is Map) Map<String, dynamic>.from(it),
    ];
  }

  int _parseTotal(Map res, int fallback) {
    final t = res['total'];
    return t is num ? t.toInt() : fallback;
  }

  /// 本地行（`cachedArticles` 的 DB 列）→ 列表卡片同构 map。
  Map<String, dynamic> _fromRow(Map<String, dynamic> r) => <String, dynamic>{
        'id': r['remoteId'],
        'localId': r['id'],
        'title': r['title'],
        'source': r['source'],
        'url': '${r['sourceUrl'] ?? r['guid'] ?? ''}',
        'word_count': r['wordCount'],
        // 本地列存毫秒；接口 items 的 published_at 是秒，卡片里统一归一。
        'published_at': r['publishedAt'],
      };

  // =====================================================================
  // 点击卡片：缓存正文 → 阅读器
  // =====================================================================

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
        // 离线列表里没有远端 id 的行：直接开本地副本。
        id = localId;
      }
      if (id == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('该文章已从源站下线')));
        }
        return;
      }
      if (!mounted) return;
      final target = id;
      ref.read(articleRevisionProvider.notifier).bump();
      await Navigator.push(
        context,
        MaterialPageRoute(
          // 传英文原标题：阅读器内标题要参与点词/TTS（中文标题会让词内 recognizer 失效），
          // 为空时由阅读器从库里兜底。
          builder: (_) => ArticleScreen(articleId: target, title: (it['title'] ?? '').toString().trim()),
        ),
      );
      // 从阅读器返回后同步「已缓存」标记。
      await _refreshCached();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：${_errOf(e)}')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _goMine() => ref.read(tabIndexProvider.notifier).set(2);

  /// 面向用户的错误文案：AppException 自带中文 message，其它回落通用提示。
  String _errOf(Object e) => e is AppException ? (e.message) : '加载失败，请稍后重试';

  // =====================================================================
  // 视图
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    // 正文缓存成功 / 列表刷新后由 articleRevision 驱动「已缓存」小标更新。
    ref.listen(articleRevisionProvider, (_, _) => _refreshCached());
    // 未内置密钥时首页显提示横幅（正常发布版不会出现）。
    final cfg = ref.watch(appConfigProvider);
    _noKey = cfg.articleApiKey.trim().isEmpty;

    return GoPage(
      topPad: false,
      globe: true,
      globeActive: ref.watch(tabIndexProvider) == 0,
      child: Stack(
        children: [
          Column(
            children: [
              GoAppBar(
                title: '时文阅读',
                style: GoAppBarStyle.floating,
                actions: [
                  GoIconBtn(icon: 'mine', onTap: _goMine),
                ],
              ),
              if (_noKey) const HomeKeyBanner(),
              if (_offline) HomeOfflineBanner(onRetry: _loadFirst),
              HomeSourceRail(sources: _sources, selected: _source, onPick: _pickSource),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _loadFirst(),
                  child: _body(),
                ),
              ),
            ],
          ),
          if (_opening) const HomeOpeningOverlay(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) return _skeletonList();
    if (_items.isEmpty && _error.isNotEmpty) return _errorList();
    if (_items.isEmpty) return _emptyList();
    return _list();
  }

  Widget _skeletonList() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp16),
      children: [for (var i = 0; i < 4; i++) _skeletonCard()],
    );
  }

  /// 简单占位块（非文字，允许固定尺寸）。
  Widget _skeletonCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: Go.sp3),
      child: GoCard(
        blur: false,
        padding: const EdgeInsets.fromLTRB(Go.sp5, Go.sp5, Go.sp5, Go.sp5),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GoSkeleton(height: 16),
            SizedBox(height: Go.sp3),
            GoSkeleton(width: 220, height: 12),
            SizedBox(height: Go.sp3),
            GoSkeleton(width: 140, height: 12),
          ],
        ),
      ),
    );
  }

  Widget _errorList() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp16),
      children: [
        GoEmpty(
          icon: 'warning',
          title: '加载失败',
          desc: _error,
          action: GoBtn(label: '重试', onTap: _loadFirst),
        ),
      ],
    );
  }

  Widget _emptyList() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp16),
      children: [
        GoEmpty(
          icon: _noKey ? 'settings' : 'book',
          title: _noKey ? '缺少文章接口密钥' : '这里还没有文章',
          desc: _noKey ? '本应用未内置文章接口密钥，暂时无法加载文章' : '下拉刷新试试',
          action: GoBtn(
            label: '刷新',
            onTap: () {
              _loadFirst();
            },
          ),
        ),
      ],
    );
  }

  Widget _list() {
    final footer = _hasMore ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp16),
      itemCount: _items.length + footer,
      itemBuilder: (context, i) {
        if (i < _items.length) {
          final it = _items[i];
          final en = (it['title'] ?? '').toString().trim();
          final url = '${it['url'] ?? ''}';
          return HomeArticleCard(
            item: it,
            zhTitle: en.isEmpty ? null : _zh[en],
            cached: url.isNotEmpty && _cached.contains(url),
            onTap: () => _openItem(it),
          );
        }
        if (_loadingMore) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: Go.sp6),
            child: Center(child: PolySpinner(size: 22)),
          );
        }
        return GestureDetector(
          onTap: _loadMore,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Go.sp5),
            child: Text(
              '加载更多',
              textAlign: TextAlign.center,
              style: TextStyle(color: GoPalette.of(context).primary, fontSize: Go.fsBodySm, fontWeight: FontWeight.w600),
            ),
          ),
        );
      },
    );
  }
}
