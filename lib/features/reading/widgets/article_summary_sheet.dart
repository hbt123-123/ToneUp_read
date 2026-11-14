import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/features/reading/controllers/reading_controller.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 「总结全文」底部弹层：AI 总结在阅读页内完成（走分析模型），结果落
/// articles.ai_summary，已总结过的文章直接展示缓存，秒出。
class ArticleSummarySheet extends ConsumerStatefulWidget {
  final ReadingController controller;
  final VoidCallback onClose;

  const ArticleSummarySheet({super.key, required this.controller, required this.onClose});

  @override
  ConsumerState<ArticleSummarySheet> createState() => _ArticleSummarySheetState();
}

class _ArticleSummarySheetState extends ConsumerState<ArticleSummarySheet> {
  bool _loading = false;
  String _error = '';
  String _summary = '';

  @override
  void initState() {
    super.initState();
    final cached = widget.controller.state.aiSummary;
    if (cached.isNotEmpty) {
      _summary = cached;
    } else {
      _run();
    }
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = '';
      _summary = '';
    });
    try {
      final out = await widget.controller.summarizeArticle();
      if (!mounted) return;
      setState(() => _summary = out);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    if (_summary.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _summary));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制总结')));
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      height: MediaQuery.of(context).size.height * 0.5,
      decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                Expanded(child: Text('总结全文', style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: g.onSurface))),
                if (_summary.isNotEmpty) _sheetBtn(g, '复制', _copy),
                const SizedBox(width: Go.sp3),
                GestureDetector(onTap: widget.onClose, child: Text('×', style: TextStyle(fontSize: 24, color: g.onSurface3))),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: g.outline),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Go.sp6),
              child: _loading
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      PolySpinner(),
                      const SizedBox(height: Go.sp3),
                      Text('AI 总结中…', style: TextStyle(color: g.onSurface3)),
                    ]))
                  : _error.isNotEmpty
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_error, style: TextStyle(color: g.danger, fontSize: Go.fsBodySm)),
                          const SizedBox(height: Go.sp3),
                          GestureDetector(onTap: _run, child: Text('重试', style: TextStyle(color: g.primary, fontWeight: FontWeight.w600))),
                        ])
                      : Text(_summary, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: g.onSurface)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetBtn(GoPalette g, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Go.sp4, vertical: Go.sp1),
          decoration: BoxDecoration(color: g.surface2, borderRadius: BorderRadius.circular(Go.rFull)),
          child: Text(label, style: TextStyle(fontSize: Go.fsMeta, color: g.onSurface)),
        ),
      );
}
