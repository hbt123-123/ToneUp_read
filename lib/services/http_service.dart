import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:toneup_read/services/app_exception.dart';

class RetryPolicy {
  final int attempts;
  final List<Duration> backoff;
  final DateTime? deadline;

  const RetryPolicy({this.attempts = 1, this.backoff = const [], this.deadline});

  static const none = RetryPolicy();
  static const batch = RetryPolicy(attempts: 2, backoff: [Duration(milliseconds: 800)]);
  static const manual = RetryPolicy(
    attempts: 3,
    backoff: [Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2)],
  );

  static RetryPolicy until(DateTime? deadline) =>
      RetryPolicy(attempts: batch.attempts, backoff: batch.backoff, deadline: deadline);
}

class HttpService {
  HttpService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const timeout = Duration(seconds: 20);

  /// 纯文本 GET（OpenGraph 抓取等）：只带调用方传入的头。
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    RetryPolicy retry = RetryPolicy.none,
  }) async {
    final res = await _send(
      () => _client.get(Uri.parse(url), headers: {...?headers}),
      url,
      retry,
    );
    if (res.bodyBytes.isEmpty) {
      throw AppException('emptyBody', '对方返回了空内容', detail: url);
    }
    return _decodeBody(res);
  }

  /// 接口类请求（LLM / 翻译）：不带 UA，只带 JSON 头与调用方自带的头。
  Future<Map<String, dynamic>> getJson(
    String url, {
    Map<String, String>? headers,
    RetryPolicy retry = RetryPolicy.none,
  }) async {
    final res = await _send(
      () => _client.get(Uri.parse(url), headers: {..._jsonHeaders, ...?headers}),
      url,
      retry,
    );
    return _asJson(res, url);
  }

  /// 同 [getJson] 的发送/重试/解码管线，但允许顶层是数组或标量
  /// （词典 `/en/<word>` 可能返回数组，`/dict` 等返回对象）。
  Future<dynamic> getJsonAny(String url, {Map<String, String>? headers, RetryPolicy retry = RetryPolicy.none}) async {
    final res = await _send(
      () => _client.get(Uri.parse(url), headers: {..._jsonHeaders, ...?headers}),
      url,
      retry,
    );
    return _decodeJson(res, url);
  }

  Future<Map<String, dynamic>> postJson(
    String url,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    RetryPolicy retry = RetryPolicy.none,
  }) async {
    final res = await _send(
      () => _client.post(Uri.parse(url), headers: {..._jsonHeaders, ...?headers}, body: jsonEncode(body)),
      url,
      retry,
    );
    return _asJson(res, url);
  }

  Future<http.Response> _send(
    Future<http.Response> Function() run,
    String url,
    RetryPolicy policy,
  ) async {
    AppException? last;
    final total = policy.attempts < 1 ? 1 : policy.attempts;
    for (var i = 0; i < total; i++) {
      final dl = policy.deadline;
      if (dl != null && DateTime.now().isAfter(dl)) {
        throw AppException('deadline', '本次刷新已超出时间预算', detail: url, retryable: true);
      }
      try {
        final res = await run().timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) return res;
        final err = _httpError(res);
        if (!err.retryable) throw err;
        last = err;
      } on AppException {
        rethrow;
      } on TimeoutException {
        last = AppException('timeout', '请求超时（${timeout.inSeconds} 秒）', detail: url, retryable: true);
      } catch (e) {
        last = AppException('network', '网络请求失败', detail: '$e', retryable: true);
      }
      if (i < policy.backoff.length) await Future.delayed(policy.backoff[i]);
    }
    throw last ?? AppException('network', '网络请求失败', detail: url, retryable: true);
  }

  AppException _httpError(http.Response res) {
    final s = res.statusCode;
    switch (s) {
      case 401:
        return AppException('http401', '接口鉴权失败（401），请检查 api key', detail: 'HTTP 401', status: s);
      case 403:
        return AppException(
          'http403',
          '对方拒绝访问（403），可尝试更换 User-Agent 或该源已失效',
          detail: 'HTTP 403',
          status: s,
        );
      case 404:
        return AppException('http404', '地址不存在（404）', detail: 'HTTP 404', status: s);
      case 408:
        return AppException('http408', '对方响应超时（408）', detail: 'HTTP 408', status: s, retryable: true);
      case 429:
        return AppException('http429', '被限流（429），请稍后再试', detail: 'HTTP 429', status: s, retryable: true);
    }
    if (s >= 500) {
      return AppException('http$s', '对方服务异常（$s）', detail: 'HTTP $s', status: s, retryable: true);
    }
    return AppException('http$s', '请求失败（$s）', detail: 'HTTP $s', status: s);
  }

  static const _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Map<String, dynamic> _asJson(http.Response res, String url) {
    final v = _decodeJson(res, url);
    if (v is Map) return Map<String, dynamic>.from(v);
    throw AppException('badJson', '接口返回了非预期的结构', detail: '${v.runtimeType}');
  }

  /// 解码响应体为 JSON：空 body 抛 `emptyBody`，坏 JSON 抛 `badJson`；
  /// 顶层可以是对象/数组/标量（由调用方决定如何收窄）。
  dynamic _decodeJson(http.Response res, String url) {
    final text = _decodeBody(res);
    if (text.trim().isEmpty) {
      throw AppException('emptyBody', '接口返回了空内容', detail: url);
    }
    try {
      return jsonDecode(text);
    } on FormatException catch (e) {
      final head = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      throw AppException('badJson', '接口返回的不是合法 JSON', detail: '${e.message} · $head');
    }
  }

  String _decodeBody(http.Response res) {
    final charset = _charsetOf(res.headers['content-type']);
    final bytes = res.bodyBytes;
    if (charset == null || charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (charset.startsWith('iso-8859') || charset == 'latin1' || charset.startsWith('windows-125')) {
      return latin1.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static final _charsetRe = RegExp(r'charset=([^;\s]+)', caseSensitive: false);

  String? _charsetOf(String? contentType) {
    if (contentType == null) return null;
    final raw = _charsetRe.firstMatch(contentType)?.group(1);
    if (raw == null) return null;
    return raw.replaceAll('"', '').replaceAll("'", '').trim().toLowerCase();
  }
}
