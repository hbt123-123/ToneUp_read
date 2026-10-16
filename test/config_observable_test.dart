import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toneup_read/providers/providers.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('配置变更会自动重建监听它的界面（无需手动 setState）', (tester) async {
    // 接口地址类配置存 SharedPreferences（明文），密钥走 Keystore/明文兜底；
    // 这里先埋一个初始地址，验证 init 读取 + 后续 setRemote 的可观察性。
    SharedPreferences.setMockInitialValues({
      'article_api_base': 'https://old.example.com',
    });
    final cfg = AppConfigService();
    await cfg.init();
    expect(cfg.articleApiBase, 'https://old.example.com', reason: '前置条件：init 应读到种子配置');

    await tester.pumpWidget(ProviderScope(
      overrides: [appConfigProvider.overrideWith((ref) => cfg)],
      child: MaterialApp(
        home: Consumer(
          builder: (c, ref, _) {
            final conf = ref.watch(appConfigProvider);
            return Text('base:${conf.articleApiBase}', textDirection: TextDirection.ltr);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('base:https://old.example.com'), findsOneWidget);

    await cfg.setRemote(articleApiBase: 'https://new.example.com');
    await tester.pumpAndSettle();

    expect(find.text('base:https://new.example.com'), findsOneWidget, reason: '配置变更应自动通知界面重建，无需手动 setState');
  });
}
