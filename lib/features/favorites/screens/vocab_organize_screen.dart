import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 词汇 AI 整理：从「我的 → 学习工具」进入，不再占用收藏页的日常管理界面。
/// 仍走 `VocabService.organize()`（按主题归类 + 释义/词族/例句），结果只在本页展示。
class VocabOrganizeScreen extends ConsumerStatefulWidget {
  const VocabOrganizeScreen({super.key});
  @override
  ConsumerState<VocabOrganizeScreen> createState() => _VocabOrganizeScreenState();
}

class _VocabOrganizeScreenState extends ConsumerState<VocabOrganizeScreen> {
  List<Map<String, dynamic>> _heads = [];
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHeads());
  }

  Future<void> _loadHeads() async {
    try {
      final svc = ref.read(vocabProvider);
      await svc.syncHeadsFromCache();
      final heads = await svc.getHeads();
      if (!mounted) return;
      setState(() {
        _heads = heads;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('词汇加载失败: $e');
    }
  }

  Future<void> _organize() async {
    if (_heads.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final res = await ref.read(vocabProvider).organize();
      if (!mounted) return;
      setState(() => _result = res);
    } catch (e) {
      if (!mounted) return;
      final msg = errText(e);
      _snack(msg.length > 60 ? msg.substring(0, 60) : msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return GoPage(
      topPad: false,
      child: Column(
        children: [
          const GoAppBar(
            title: 'AI 整理收藏',
            style: GoAppBarStyle.floating,
            leading: GoBack(),
          ),
          Expanded(child: _body(g)),
        ],
      ),
    );
  }

  Widget _body(GoPalette g) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PolySpinner(),
            const SizedBox(height: Go.sp6),
            Text('正在读取收藏…', style: TextStyle(color: g.onSurface3, fontSize: Go.fsBodySm)),
          ],
        ),
      );
    }
    if (_heads.isEmpty) {
      return const GoEmpty(
        icon: 'book',
        title: '还没有收藏的词汇',
        desc: '先去正文里点几个词，再回来整理',
      );
    }
    final groups = (_result?['groups'] as List?) ?? const [];
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + Go.sp16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(Go.sp6, Go.sp4, Go.sp6, Go.sp6),
            padding: const EdgeInsets.all(Go.sp5),
            decoration: BoxDecoration(color: g.primary95, borderRadius: BorderRadius.circular(Go.rLg)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 会按主题归类这 ${_heads.length} 个词族，并补全释义、词族与例句。',
                    style: TextStyle(fontSize: Go.fsBodySm, height: Go.lhNormal, color: g.onSurface)),
                const SizedBox(height: Go.sp4),
                GoBtn(
                  label: _result == null ? '开始整理' : '重新整理',
                  icon: GoIcon('robot', size: 16, color: g.onPrimary),
                  enabled: !_busy,
                  onTap: _organize,
                ),
              ],
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Go.sp8),
              child: Column(
                children: [
                  const PolySpinner(),
                  const SizedBox(height: Go.sp3),
                  Text('AI 正在整理…', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
                ],
              ),
            ),
          if (!_busy && _result != null && groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Go.sp6, vertical: Go.sp5),
              child: Text('这次没有整理出可用的分组，稍后重试。', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface3)),
            ),
          if (!_busy)
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.fromLTRB(Go.sp6, 0, Go.sp6, Go.sp6),
                child: _group(g, group),
              ),
        ],
      ),
    );
  }

  Widget _group(GoPalette g, dynamic group) {
    final items = (group['items'] as List?) ?? const [];
    return Container(
      padding: const EdgeInsets.all(Go.sp5),
      decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rLg), border: Border.all(color: g.outline, width: 0.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Go.sp3, vertical: 1),
            decoration: BoxDecoration(color: g.primary95, borderRadius: BorderRadius.circular(Go.rFull)),
            child: Text('${group['theme'] ?? '未命名主题'}',
                style: TextStyle(fontSize: Go.fsMeta, fontWeight: FontWeight.w600, color: g.primary)),
          ),
          const SizedBox(height: Go.sp2),
          for (final it in items) _item(g, it),
        ],
      ),
    );
  }

  Widget _item(GoPalette g, dynamic it) => Container(
        padding: const EdgeInsets.symmetric(vertical: Go.sp3),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: g.outline, width: 0.5))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${it['word']}  ${it['pos'] ?? ''}', style: TextStyle(fontSize: Go.fsBody, fontWeight: FontWeight.w600, color: g.onSurface)),
            Text('${it['zh'] ?? ''}', style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface)),
            Text('${it['en'] ?? ''}', style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3)),
            Text('词族：${(it['family'] as List? ?? const []).join(', ')}', style: TextStyle(fontSize: Go.fsMeta, color: g.primary)),
            Text('e.g. ${it['example'] ?? ''}',
                style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface3, fontStyle: FontStyle.italic)),
          ],
        ),
      );
}
