import 'package:flutter/material.dart';
import 'package:toneup_read/theme/go_tokens.dart';
import 'package:toneup_read/widgets/go_ui.dart';

/// 首页品牌区：ToneUP·read 大标题 + 欢迎语 + 搜索入口。
/// 自带状态栏安全区 padding（GoPage 传 topPad:false，由这里补）。
class HomeHeader extends StatelessWidget {
  final VoidCallback onSearch;

  const HomeHeader({super.key, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final g = GoPalette.of(context);
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(Go.sp4, top + Go.sp4, Go.sp4, Go.sp2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 品牌：两种颜色拼出 ToneUP·read，纯装饰文字不参与点词。
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'ToneUP', style: TextStyle(color: g.onSurface)),
                      TextSpan(text: '·read', style: TextStyle(color: g.primary)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: Go.fsDisplay, fontWeight: FontWeight.w800, height: Go.lhTight, letterSpacing: 0.3),
                ),
                const SizedBox(height: Go.sp1),
                Text(
                  '今天读点什么',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: Go.fsBodySm, color: g.onSurface3),
                ),
              ],
            ),
          ),
          const SizedBox(width: Go.sp3),
          GoIconBtn(icon: 'search', onTap: onSearch),
        ],
      ),
    );
  }
}
