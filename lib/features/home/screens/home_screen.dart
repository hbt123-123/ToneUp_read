import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/home/screens/home_search_screen.dart';
import 'package:toneup_read/features/home/widgets/article_card.dart';
import 'package:toneup_read/features/home/widgets/category_rail.dart';
import 'package:toneup_read/features/home/widgets/continue_card.dart';
import 'package:toneup_read/features/home/widgets/featured_card.dart';
import 'package:toneup_read/features/home/widgets/home_header.dart';
import 'package:toneup_read/features/home/widgets/home_notice.dart';
import 'package:toneup_read/features/reading/screens/article_screen.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/remote_article_service.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 首页（精品阅读）：品牌区 + 精选大卡 + 分类浏览 + 最近阅读 + 最新文章。
///
/// - 列表走 `remoteArticleProvider.list`（page/perPage=20 分页），拉到后批量取
///   中文标题（`titleZhBatch`）并静默补齐主题（`ensureTopics` → 分类过滤用）。
/// - 精选每日轮换：从最新 5 篇按当天日期稳定选一篇。
/// - 分类是本地概念：`ai_verdict.topics` 映射成中文分类，对新文章逐渐填齐。
/// - 「最近阅读」来自 articles.lastOpenedAt / readProgress（阅读器写入），
///   点击用 `focusPara` 恢复到上次读到的段落。
/// - 文字一律只给 `maxLines`/`overflow`，不套固定高度（textScaler 回归铁律）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const int _perPage = 20;
  static const int _featuredPool = 5;

  /// 距底部还剩多少像素时自动续页。
  static const double _loadMoreThreshold = 300;

  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scroll = ScrollController();

  /// 已缓存正文的 guid（= url）集合，卡片右上「已缓存」小标。
  final Set<String> _cached = {};

  /// 英文标题 → 中文标题。
  final Map<String, String> _zh = {};

  /// 最近阅读的本地行（articles 列）+ 其中译标题；null = 还没读过。
  Map<String, dynamic>? _continueRow;
  String? _continueZh;

  String? _category; // null = 全部；kCategories 的 key
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadContinue();
      _loadFirst();
    });
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
          await ref.read(remoteArticleProvider).list(page: 1, perPage: _perPage);
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
      });
      await _fillZh(rows);
      await _refreshCached();
      _applyTopics(rows);
    } catch (e) {
      // 列表失败 → 离线兜底：本地已缓存的行。
      var cached = const <Map<String, dynamic>>[];
      try {
        cached = await ref.read(remoteArticleProvider).cachedArticles();
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
          .list(page: next, perPage: _perPage);
      final rows = _parseItems(res);
      if (!mounted) return;
      final added = <Map<String, dynamic>>[];
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
          added.add(r);
        }
        _page = next;
        _total = _parseTotal(res, _total);
        _loadingMore = false;
      });
      await _fillZh(added);
      _applyTopics(added);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载更多失败：${_errOf(e)}')));
    }
  }

  /// 静默补齐主题（分类浏览的数据源）：先读回本地 aiVerdict，缺的拉详情补全。
  /// 完成后合并进内存 items（it['topics'] = 中文分类 key 列表）。
  Future<void> _applyTopics(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    try {
      final got = await ref.read(remoteArticleProvider).ensureTopics(rows);
      if (!mounted || got.isEmpty) return;
      setState(() {
        for (final it in _items) {
          final rid = it['id'] is num ? (it['id'] as num).toInt() : null;
          final t = rid == null ? null : got[rid];
          if (t == null || t.isEmpty) continue;
          it['topics'] = categoriesOfTopics(t);
        }
      });
    } catch (_) {
      // 分类补全是增强，失败不影响列表。
    }
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

  /// 「最近阅读」卡：最近一条 lastOpenedAt；从阅读器返回后重查（进度刚被写入）。
  Future<void> _loadContinue() async {
    try {
      final rows = await ref.read(remoteArticleProvider).recentlyRead(1);
      if (!mounted) return;
      String? zh;
      if (rows.isNotEmpty) {
        final t = '${rows.first['title'] ?? ''}'.trim();
        if (t.isNotEmpty) {
          final m = await ref.read(remoteArticleProvider).titleZhBatch([t]);
          zh = m[t];
        }
      }
      if (!mounted) return;
      setState(() {
        _continueRow = rows.isEmpty ? null : rows.first;
        _continueZh = (zh == null || zh.trim().isEmpty) ? null : zh.trim();
      });
    } catch (_) {
      // 最近阅读拿不到不影响首页其它部分。
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
        // 离线行自带 aiVerdict，分类直接可用。
        'topics': categoriesOfTopics(RemoteArticleService.topicsFromVerdict(r['aiVerdict'] as String?)),
      };

  // =====================================================================
  // 派生数据
  // =====================================================================

  /// 精选文章：从最新 [_featuredPool] 篇按当天日期稳定选一篇（每日轮换）。
  Map<String, dynamic>? _featuredOf() {
    if (_items.isEmpty) return null;
    final pool = _items.take(_featuredPool).toList();
    final now = DateTime.now();
    final dayKey = now.year * 10000 + now.month * 100 + now.day;
    return pool[dayKey % pool.length];
  }

  /// 分类过滤后的列表（分类是本地 topics 概念，内存过滤）。
  List<Map<String, dynamic>> _visibleItems() {
    if (_category == null) return _items;
    return [
      for (final it in _items)
        if (it['topics'] is List && (it['topics'] as List).contains(_category)) it,
    ];
  }

  String? _zhOf(Map<String, dynamic> it) {
    final en = '${it['title'] ?? ''}'.trim();
    return en.isEmpty ? null : _zh[en];
  }

  bool _isCached(Map<String, dynamic> it) {
    final url = '${it['url'] ?? ''}';
    return url.isNotEmpty && _cached.contains(url);
  }

  // =====================================================================
  // 动作
  // =====================================================================

  void _pickCategory(String? key) {
    if (_category == key) return;
    setState(() => _category = key);
  }

  void _goSearch() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const HomeSearchScreen()));
  }

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
      // 从阅读器返回后同步「已缓存」标记与「最近阅读」进度。
      await _refreshCached();
      await _loadContinue();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：${_errOf(e)}')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// 从上次读到的段落继续（阅读器 focusPara 定位机制）。
  Future<void> _openContinue() async {
    final row = _continueRow;
    if (row == null) return;
    final id = row['id'] is num ? (row['id'] as num).toInt() : null;
    if (id == null || id <= 0) return;
    final lastPara = row['lastPara'] is num ? (row['lastPara'] as num).toInt() : -1;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArticleScreen(
          articleId: id,
          title: '${row['title'] ?? ''}'.trim(),
          focusPara: lastPara >= 0 ? lastPara : -1,
        ),
      ),
    );
    await _loadContinue();
  }

  /// 面向用户的错误文案：AppException 自带中文 message，其它回落通用提示。
  String _errOf(Object e) => e is AppException ? (e.message) : '加载失败，请稍后重试';

  // =====================================================================
  // 视图
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    // 正文缓存成功 / 列表刷新后由 articleRevision 驱动「已缓存」小标更新；
    // 搜索页等其它入口打开文章后，这里同时重查「最近阅读」
    // （IndexedStack 常驻页只能靠信号刷新；首页自身 _openItem 的 bump 在 push 前
    // 触发一次旧值查询，push 返回后另有显式重查，不受影响）。
    ref.listen(articleRevisionProvider, (_, _) {
      _refreshCached();
      _loadContinue();
    });
    // 未内置密钥时首页显提示横幅（正常发布版不会出现）。
    final cfg = ref.watch(appConfigProvider);
    _noKey = cfg.articleApiKey.trim().isEmpty;

    return GoPage(
      topPad: false,
      globe: true,
      globeActive: ref.watch(tabIndexProvider) == 0,
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _loadFirst,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: HomeHeader(onSearch: _goSearch)),
                if (_noKey) const SliverToBoxAdapter(child: HomeKeyBanner()),
                if (_offline) SliverToBoxAdapter(child: HomeOfflineBanner(onRetry: _loadFirst)),
                ..._bodySlivers(),
              ],
            ),
          ),
          if (_opening) const HomeOpeningOverlay(),
        ],
      ),
    );
  }

  List<Widget> _bodySlivers() {
    if (_loading && _items.isEmpty) return _skeletonSlivers();
    if (_items.isEmpty && _error.isNotEmpty) return _errorSlivers();
    if (_items.isEmpty) return _emptySlivers();
    return _contentSlivers();
  }

  // ---------------------------------------------------------------- 骨架

  List<Widget> _skeletonSlivers() {
    return [
      // 精选卡骨架（固定尺寸的是背景块，非文字）。
      SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.fromLTRB(Go.sp4, Go.sp2, Go.sp4, Go.sp4),
          child: GoCard(
            blur: false,
            padding: EdgeInsets.zero,
            radius: Go.rXl,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GoSkeleton(height: 150, radius: 0),
                Padding(
                  padding: const EdgeInsets.all(Go.sp5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      GoSkeleton(height: 16),
                      SizedBox(height: Go.sp3),
                      GoSkeleton(width: 220, height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      // 分类 chips 骨架。
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp3),
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: Go.sp2),
                const GoSkeleton(width: 56, height: 32, radius: 16),
              ],
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: Go.sp4),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            for (var i = 0; i < 3; i++) _skeletonCard(),
          ]),
        ),
      ),
    ];
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

  // ------------------------------------------------------------ 错误/空态

  List<Widget> _errorSlivers() {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: GoEmpty(
            icon: 'warning',
            title: '加载失败',
            desc: _error,
            action: GoBtn(label: '重试', onTap: _loadFirst),
          ),
        ),
      ),
    ];
  }

  List<Widget> _emptySlivers() {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: GoEmpty(
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
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- 主体

  List<Widget> _contentSlivers() {
    final featured = _featuredOf();
    final visible = _visibleItems();
    final footer = _hasMore && _category == null ? 1 : 0;
    return [
      // 精选大卡。
      if (featured != null)
        SliverToBoxAdapter(
          child: HomeFeaturedCard(
            item: featured,
            zhTitle: _zhOf(featured),
            cached: _isCached(featured),
            onTap: () => _openItem(featured),
          ),
        ),
      // 分类浏览。
      SliverToBoxAdapter(child: HomeCategoryRail(selected: _category, onPick: _pickCategory)),
      // 最近阅读（读过文章才出现）。
      if (_continueRow != null)
        SliverToBoxAdapter(
          child: HomeContinueCard(row: _continueRow!, zhTitle: _continueZh, onTap: _openContinue),
        ),
      // 最新文章（筛选时标题换成分类名）。
      SliverToBoxAdapter(child: _listTitle(context, visible)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Go.sp4, 0, Go.sp4, Go.sp16),
        sliver: visible.isEmpty
            ? SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: GoEmpty(
                    icon: 'book',
                    title: '这个分类还没有文章',
                    desc: '打开文章后会自动按主题归类，稍后再来看看',
                  ),
                ),
              )
            : SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i < visible.length) {
                      final it = visible[i];
                      return HomeArticleCard(
                        item: it,
                        zhTitle: _zhOf(it),
                        cached: _isCached(it),
                        onTap: () => _openItem(it),
                      );
                    }
                    // footer：分类过滤时列表来自内存，不再分页。
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
                          style: TextStyle(
                            color: GoPalette.of(context).primary,
                            fontSize: Go.fsBodySm,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    );
                  },
                  childCount: visible.length + footer,
                ),
              ),
      ),
    ];
  }

  Widget _listTitle(BuildContext context, List<Map<String, dynamic>> visible) {
    final g = GoPalette.of(context);
    final label = _category == null
        ? '最新文章'
        : kCategories.firstWhere((c) => c.key == _category, orElse: () => kCategories.first).label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Go.sp4, Go.sp6, Go.sp4, Go.sp2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Go.fsMeta,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: g.onSurface3,
              ),
            ),
          ),
          if (_category != null)
            Text(
              '${visible.length} 篇',
              maxLines: 1,
              style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3),
            ),
        ],
      ),
    );
  }
}
