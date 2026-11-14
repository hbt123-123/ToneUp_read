import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 划词「翻译」的底部弹层：网关翻译结果 + 复制。
class SentenceActionSheet extends ConsumerStatefulWidget {
  final String text;
  final VoidCallback onClose;
  const SentenceActionSheet({super.key, required this.text, required this.onClose});
  @override
  ConsumerState<SentenceActionSheet> createState() => _SentenceActionSheetState();
}

class _SentenceActionSheetState extends ConsumerState<SentenceActionSheet> {
  bool _loading = true;
  String _error = '';
  String _out = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = '';
      _out = '';
    });
    try {
      final r = await ref.read(translateProvider).translate(widget.text);
      if (!mounted) return;
      if (r.trim().isEmpty) {
        setState(() => _error = '翻译结果为空，请重试');
      } else {
        setState(() => _out = r.trim());
      }
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    return Container(
      height: MediaQuery.of(context).size.height * 0.45,
      decoration: BoxDecoration(color: g.surfaceRaised, borderRadius: const BorderRadius.vertical(top: Radius.circular(Go.rXl))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Go.sp6, Go.sp5, Go.sp6, Go.sp3),
            child: Row(
              children: [
                Expanded(child: Text('翻译', style: TextStyle(fontSize: Go.fsTitle, fontWeight: FontWeight.w600, color: g.onSurface))),
                if (_out.isNotEmpty)
                  _sheetBtn(g, '复制', () async {
                    await Clipboard.setData(ClipboardData(text: _out));
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制译文')));
                  }),
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
                      child: Column(mainAxisSize: MainAxisSize.min, children: [PolySpinner(), SizedBox(height: Go.sp3), Text('翻译中…', style: TextStyle(color: g.onSurface3))]))
                  : _error.isNotEmpty
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_error, style: TextStyle(color: g.danger, fontSize: Go.fsBodySm)),
                          const SizedBox(height: Go.sp3),
                          GestureDetector(onTap: _run, child: Text('重试', style: TextStyle(color: g.primary, fontWeight: FontWeight.w600))),
                        ])
                      : Text(_out, style: TextStyle(fontSize: Go.fsBody, height: Go.lhRelaxed, color: g.onSurface)),
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
