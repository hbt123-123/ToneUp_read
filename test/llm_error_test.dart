import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';

/// chat 会先要求网关密钥。FLUTTER_TEST 下 Keystore 不可用，`AppConfigService`
/// 会回落到 SharedPreferences 的明文键 `gateway_key`，所以这里用 mock prefs 注入。
Future<LlmService> _service(http.Client client, {bool withKey = true}) async {
  SharedPreferences.setMockInitialValues(withKey ? {'gateway_key': 'test-key'} : <String, Object>{});
  final cfg = AppConfigService();
  await cfg.init();
  return LlmService(HttpService(client: client), cfg);
}

String _reply(String content) => '{"choices":[{"message":{"content":"$content"}}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未配置网关密钥时抛 llmKey，且一个请求都不发', () async {
    var calls = 0;
    final svc = await _service(MockClient((req) async {
      calls++;
      return http.Response(_reply('hi'), 200);
    }), withKey: false);
    await expectLater(
      svc.chat('s', 'u'),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'llmKey')
          .having((e) => e.message, 'message', contains('网关密钥'))),
    );
    expect(calls, 0, reason: '缺 key 必须在发起请求前失败');
  });

  test('401 变成可操作的提示', () async {
    final svc = await _service(MockClient((req) async => http.Response('{"error":{"message":"invalid key"}}', 401)));
    await expectLater(
      svc.chat('s', 'u'),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'llmKey')
          .having((e) => e.message, 'message', contains('网关密钥'))
          .having((e) => e.status, 'status', 401)),
    );
  });

  test('404 提示检查 base url', () async {
    final svc = await _service(MockClient((req) async => http.Response('not found', 404)));
    await expectLater(svc.chat('s', 'u'), throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmUrl')));
  });

  test('429 归类为限流且会重试', () async {
    var calls = 0;
    final svc = await _service(MockClient((req) async {
      calls++;
      return http.Response('{"error":"rate limit"}', 429);
    }));
    await expectLater(svc.chat('s', 'u'), throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmRate')));
    expect(calls, greaterThan(1));
  });

  test('5xx 保留可重试标记并带上网关地址', () async {
    var calls = 0;
    final svc = await _service(MockClient((req) async {
      calls++;
      return http.Response('boom', 500);
    }));
    await expectLater(
      svc.chat('s', 'u'),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'http500')
          .having((e) => e.retryable, 'retryable', isTrue)
          .having((e) => e.message, 'message', contains(AppConfigService.defaultGatewayBase))),
    );
    expect(calls, greaterThan(1), reason: '5xx 可重试，应按 manual 策略重发');
  });

  test('返回 HTML 时是 llmFormat 而不是 FormatException', () async {
    final svc = await _service(MockClient((req) async => http.Response('<html>502 Bad Gateway</html>', 200)));
    await expectLater(svc.chat('s', 'u'), throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmFormat')));
  });

  test('空 content 视为失败', () async {
    final svc = await _service(MockClient((req) async => http.Response(_reply(''), 200)));
    await expectLater(svc.chat('s', 'u'), throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmEmpty')));
  });

  test('缺 content 字段也视为失败', () async {
    final svc = await _service(MockClient((req) async => http.Response('{"choices":[{"message":{}}]}', 200)));
    await expectLater(svc.chat('s', 'u'), throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmEmpty')));
  });

  test('正常返回内容，且请求确实带上配置的密钥', () async {
    late http.Request seen;
    final svc = await _service(MockClient((req) async {
      seen = req;
      return http.Response(_reply('hello'), 200);
    }));
    expect(await svc.chat('s', 'u'), 'hello');
    expect(seen.headers['Authorization'], 'Bearer test-key');
    expect(seen.url.toString(), '${AppConfigService.defaultGatewayBase}/v1/chat/completions');
  });

  group('超长正文截断', () {
    test('短文原样返回', () {
      expect(LlmService.clipArticle('short'), 'short');
    });

    test('超长文被截到上限以内', () {
      final long = List.filled(400, 'A sentence in the article body. ' * 20).join('\n\n');
      expect(long.length, greaterThan(LlmService.maxPromptChars));
      expect(LlmService.clipArticle(long).length, lessThanOrEqualTo(LlmService.maxPromptChars));
    });

    test('优先在段落边界断开，不切半句', () {
      final para = 'This is a full sentence in a paragraph. ' * 20;
      final long = List.filled(400, para).join('\n\n');
      final out = LlmService.clipArticle(long);
      // 断在段落边界上：结尾不该是空行（否则会多带一个截断标记进来）
      expect(out.endsWith('\n'), isFalse);
      expect(out.endsWith('\n\n'), isFalse);
      // 截断后仍以完整句子收尾（句号结尾），而不是半个单词
      expect(out.trimRight().endsWith('.'), isTrue);
    });

    test('没有换行的超长文本也能被截断', () {
      expect(LlmService.clipArticle('a' * 50000).length, lessThanOrEqualTo(LlmService.maxPromptChars));
    });

    test('恰好等于上限时不动', () {
      final exact = 'x' * LlmService.maxPromptChars;
      expect(LlmService.clipArticle(exact), exact);
    });
  });
}
