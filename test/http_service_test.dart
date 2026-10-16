import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:toneup_read/services/app_exception.dart';
import 'package:toneup_read/services/http_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('接口请求（LLM/翻译）带 JSON 头且不带 UA', () async {
    late http.Request seen;
    final svc = HttpService(
      client: MockClient((req) async {
        seen = req;
        return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
      }),
    );
    await svc.getJson('https://api.example.com/v1/models');
    expect(seen.headers.containsKey('user-agent'), isFalse);
    expect(seen.headers['Accept'], 'application/json');
    expect(seen.headers['Content-Type'], 'application/json');
  });

  test('403 不重试并给出可读原因', () async {
    var calls = 0;
    final svc = HttpService(
      client: MockClient((req) async {
        calls++;
        return http.Response('forbidden', 403);
      }),
    );
    await expectLater(
      svc.getText('https://example.com/', retry: const RetryPolicy(attempts: 3, backoff: [Duration.zero, Duration.zero])),
      throwsA(isA<AppException>()
          .having((e) => e.code, 'code', 'http403')
          .having((e) => e.retryable, 'retryable', isFalse)),
    );
    expect(calls, 1);
  });

  test('429 会按策略重试', () async {
    var calls = 0;
    final svc = HttpService(
      client: MockClient((req) async {
        calls++;
        return http.Response('slow down', 429);
      }),
    );
    await expectLater(
      svc.getText('https://example.com/', retry: const RetryPolicy(attempts: 2, backoff: [Duration.zero])),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'http429')),
    );
    expect(calls, 2);
  });

  test('5xx 第一次失败、重试成功', () async {
    var calls = 0;
    final svc = HttpService(
      client: MockClient((req) async {
        calls++;
        if (calls == 1) return http.Response('oops', 503);
        return http.Response('recovered', 200);
      }),
    );
    final body = await svc.getText('https://example.com/', retry: const RetryPolicy(attempts: 3, backoff: [Duration.zero]));
    expect(body, 'recovered');
    expect(calls, 2);
  });

  test('401/404 不重试', () async {
    for (final code in [401, 404]) {
      var calls = 0;
      final svc = HttpService(
        client: MockClient((req) async {
          calls++;
          return http.Response('nope', code);
        }),
      );
      await expectLater(
        svc.getText('https://example.com/', retry: const RetryPolicy(attempts: 3, backoff: [Duration.zero])),
        throwsA(isA<AppException>()),
      );
      expect(calls, 1, reason: '$code 不应重试');
    }
  });

  test('超出时间预算时直接放弃', () async {
    var calls = 0;
    final svc = HttpService(
      client: MockClient((req) async {
        calls++;
        return http.Response('x', 503);
      }),
    );
    await expectLater(
      svc.getText('https://example.com/', retry: RetryPolicy.until(DateTime.now().subtract(const Duration(seconds: 1)))),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'deadline')),
    );
    expect(calls, 0);
  });

  test('200 但空 body 视为失败', () async {
    final svc = HttpService(client: MockClient((req) async => http.Response('', 200)));
    await expectLater(
      svc.getText('https://example.com/'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'emptyBody')),
    );
  });

  test('按 content-type 的 charset 解码，非 UTF-8 不再抛异常', () async {
    final svc = HttpService(client: MockClient((req) async {
      return http.Response.bytes(
        [0x63, 0x61, 0x66, 0xE9],
        200,
        headers: {'content-type': 'text/html; charset=ISO-8859-1'},
      );
    }));
    expect(await svc.getText('https://example.com/'), 'café');

    final svc2 = HttpService(client: MockClient((req) async {
      return http.Response.bytes([0x63, 0x61, 0x66, 0xE9], 200, headers: {'content-type': 'text/html'});
    }));
    expect(await svc2.getText('https://example.com/'), isNot(throwsA(anything)));
  });

  test('JSON 接口返回 HTML 时给出可读错误而不是 FormatException', () async {
    final svc = HttpService(client: MockClient((req) async => http.Response('<!DOCTYPE html><html>502</html>', 200)));
    await expectLater(
      svc.getJson('https://api.example.com/chat'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'badJson')),
    );
  });

  group('getJsonAny：顶层可以是数组或对象（词典 /dict 与 /en/<word> 两种形态）', () {
    test('顶层数组可解析', () async {
      final svc = HttpService(client: MockClient((req) async => http.Response('[{"word":"a"},2]', 200)));
      final v = await svc.getJsonAny('https://api.example.com/en/a');
      expect(v, isA<List<dynamic>>());
      expect((v as List).first, {'word': 'a'});
    });

    test('顶层对象可解析', () async {
      final svc = HttpService(client: MockClient((req) async => http.Response('{"kind":"dict"}', 200)));
      final v = await svc.getJsonAny('https://api.example.com/dict');
      expect(v, isA<Map<String, dynamic>>());
      expect(v['kind'], 'dict');
    });

    test('坏 JSON 抛 badJson', () async {
      final svc = HttpService(client: MockClient((req) async => http.Response('<html>oops</html>', 200)));
      await expectLater(
        svc.getJsonAny('https://api.example.com/dict'),
        throwsA(isA<AppException>().having((e) => e.code, 'code', 'badJson')),
      );
    });

    test('空 body 抛 emptyBody', () async {
      final svc = HttpService(client: MockClient((req) async => http.Response('', 200)));
      await expectLater(
        svc.getJsonAny('https://api.example.com/dict'),
        throwsA(isA<AppException>().having((e) => e.code, 'code', 'emptyBody')),
      );
    });
  });

  test('约定的重试参数被固定下来', () {
    expect(RetryPolicy.batch.attempts, 2);
    expect(RetryPolicy.batch.backoff, [const Duration(milliseconds: 800)]);
    expect(RetryPolicy.manual.attempts, 3);
    expect(RetryPolicy.manual.backoff, [const Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2)]);
    expect(RetryPolicy.none.attempts, 1);
  });
}
