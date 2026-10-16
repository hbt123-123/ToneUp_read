import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/translate_service.dart';

const String _base = 'https://gw.test';
const String _key = 'gw-key';

Map<String, String> get _jsonHeaders => {'content-type': 'application/json'};

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: _jsonHeaders);

/// 按源码读取路径注入：`gateway_base` / `gateway_key` / `gateway_model`
/// （FLUTTER_TEST 下密钥回落明文 `gateway_key`）。
Future<AppConfigService> _config({String gatewayKey = _key}) async {
  SharedPreferences.setMockInitialValues({
    'gateway_base': _base,
    'gateway_key': gatewayKey,
    'gateway_model': 'my-model',
  });
  final cfg = AppConfigService();
  await cfg.init();
  return cfg;
}

/// 单引擎翻译：TranslateService(LlmService(HttpService(client: mock), cfg))。
Future<TranslateService> _svc(http.Client client, {String gatewayKey = _key}) async =>
    TranslateService(LlmService(HttpService(client: client), await _config(gatewayKey: gatewayKey)));

http.Response _reply(String content, {String pad = ''}) =>
    _ok({'choices': [
      {
        'message': {'content': '$pad$content$pad'},
      },
    ]});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('成功路径：POST /v1/chat/completions、Bearer 鉴权、body 带 model 与用户文本', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(MockClient((req) async {
      reqs.add(req);
      return _reply('你好，世界', pad: '  ');
    }));

    expect(await svc.translate('Hello world'), '你好，世界', reason: '返回值去掉首尾空白');

    expect(reqs, hasLength(1));
    final req = reqs.single;
    expect(req.method, 'POST');
    expect(req.url.toString(), '$_base/v1/chat/completions');
    expect(req.headers['Authorization'], 'Bearer $_key');

    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['model'], 'my-model');
    expect(body['temperature'], 0.7);
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages, hasLength(2));
    expect(messages[0]['role'], 'system');
    expect('${messages[0]['content']}', contains('translator'));
    expect(messages[1]['role'], 'user');
    expect('${messages[1]['content']}', contains('Translate the following text from en to zh.'));
    expect('${messages[1]['content']}', contains('<<<\nHello world\n>>>'));
  });

  test('from/to 写进用户文本', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(MockClient((req) async {
      reqs.add(req);
      return _reply('Hello');
    }));

    expect(await svc.translate('你好', from: 'zh', to: 'en'), 'Hello');
    expect(reqs, hasLength(1));
    final body = jsonDecode(reqs.single.body) as Map<String, dynamic>;
    final user = '${(body['messages'] as List)[1]['content']}';
    expect(user, contains('from zh to en'));
    expect(user, contains('<<<\n你好\n>>>'));
  });

  test('空白文本直接返回空串，不发请求', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(MockClient((req) async {
      reqs.add(req);
      return _reply('不该被打到');
    }));

    expect(await svc.translate('   '), '');
    expect(reqs, isEmpty);
  });

  test('未配置密钥抛 llmKey，且不发请求', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(
      MockClient((req) async {
        reqs.add(req);
        return _reply('不该被打到');
      }),
      gatewayKey: '',
    );

    await expectLater(
      svc.translate('Hello'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmKey')),
    );
    expect(reqs, isEmpty);
  });

  test('坏 JSON 直接抛错（无任何回落引擎），只发一次请求', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(MockClient((req) async {
      reqs.add(req);
      return http.Response('<html>502 Bad Gateway</html>', 200, headers: _jsonHeaders);
    }));

    await expectLater(
      svc.translate('Hello'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'llmFormat')),
    );
    expect(reqs, hasLength(1), reason: '坏 JSON 不重试、也没有其它翻译引擎可回落');
    expect(reqs.single.url.toString(), '$_base/v1/chat/completions');
  });

  test('网关 500 直接抛错（无回落），重试次数由 RetryPolicy.manual 决定', () async {
    final reqs = <http.Request>[];
    final svc = await _svc(MockClient((req) async {
      reqs.add(req);
      return http.Response('boom', 500);
    }));

    await expectLater(
      svc.translate('Hello'),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'http500')
          .having((e) => e.retryable, 'retryable', isTrue)),
    );
    // 源码里 LlmService.chat 固定 retry: RetryPolicy.manual（attempts:3，退避 500ms/1s/2s），
    // 所以 5xx 会打满 3 次并最终抛错——没有任何回落引擎。
    expect(reqs, hasLength(RetryPolicy.manual.attempts));
    expect(reqs.every((r) => r.url.toString() == '$_base/v1/chat/completions'), isTrue);
    expect(reqs.every((r) => r.method == 'POST'), isTrue);
  });
}
