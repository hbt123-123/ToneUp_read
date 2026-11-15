import 'dart:convert';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/app_exception.dart';

class LlmService {
  final HttpService _http;
  final AppConfigService _cfg;
  LlmService(this._http, this._cfg);

  /// 送进 prompt 的正文上限（字符）。约等于 3k token 的英文，超出部分多数模型会直接报错或静默截断。
  static const int maxPromptChars = 12000;

  /// AI 生成请求的单次等待上限。全局 20 秒是给列表/词典这类短接口的；
  /// 一次整理/精选要几十秒，按 20 秒必超时。网关在 Cloudflare Worker 上，
  /// 约 100 秒会被 524 截断，客户端等更久没有意义。
  static const Duration requestTimeout = Duration(seconds: 90);

  /// 单次请求的输出上限。不传时上游默认上限约 4k token，长 JSON（如批量整理）
  /// 会被从中间截断，尾部 `]}` 缺失导致解析失败。
  static const int maxTokens = 8192;

  /// 截断过长正文。优先在段落边界断开，避免只切半句话导致题目失真。
  static String clipArticle(String text, {int limit = maxPromptChars}) {
    if (text.length <= limit) return text;
    final cut = text.substring(0, limit);
    final br = cut.lastIndexOf('\n');
    return (br > limit ~/ 2 ? cut.substring(0, br) : cut).trim();
  }

  /// 走翻译网关（OpenAI 兼容）的一次对话调用。
  /// [model] 传空时用配置的默认模型；总结/长难句解析等理解型任务传
  /// `AppConfigService.defaultGatewayAnalysisModel`（网关透传 SiliconFlow 的 model 参数）。
  /// [timeout] 默认按 AI 生成请求的 90 秒；短文本翻译应传更小的值。
  Future<String> chat(
    String system,
    String user, {
    double temperature = 0.7,
    String? model,
    Duration timeout = requestTimeout,
  }) async {
    final key = _cfg.gatewayKey.trim();
    if (key.isEmpty) {
      throw AppException(
        'llmKey',
        '本应用未内置翻译网关密钥，无法翻译',
      );
    }
    final url = '${_cfg.gatewayBase}/v1/chat/completions';
    final m = (model != null && model.trim().isNotEmpty) ? model.trim() : _cfg.gatewayModel;
    final body = {
      'model': m,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
      // 关闭 Qwen3 的思考模式（SiliconFlow 扩展参数）：思考模式会先输出一大段
      // reasoning，既慢又会把 JSON 输出弄坏；混元等翻译模型忽略该字段。
      'enable_thinking': false,
    };
    final Map<String, dynamic> res;
    try {
      res = await _http.postJson(
        url,
        body,
        headers: {'Authorization': 'Bearer $key'},
        retry: RetryPolicy.ai,
        timeout: timeout,
      );
    } on AppException catch (e) {
      throw _readable(e);
    }
    final choices = res['choices'];
    if (choices is! List || choices.isEmpty) {
      final err = res['error'];
      final msg = err is Map ? (err['message'] ?? '$err') : (res['message'] ?? '$res');
      throw AppException('llmEmpty', '模型没有返回内容', detail: '$msg');
    }
    final first = choices.first;
    if (first is! Map || first['message'] is! Map) {
      throw AppException('llmFormat', '模型返回格式异常', detail: '$first');
    }
    final content = ((first['message'] as Map)['content'] ?? '').toString().trim();
    if (content.isEmpty) {
      throw AppException('llmEmpty', '模型返回了空内容', detail: 'choices[0].message.content 为空');
    }
    return content;
  }

  AppException _readable(AppException e) {
    switch (e.code) {
      case 'http401':
        return AppException('llmKey', '网关密钥无效或已失效（401），请联系服务提供方', detail: e.detail, status: e.status);
      case 'http403':
        return AppException('llmKey', '网关拒绝访问（403），该网关密钥可能无权访问此模型', detail: e.detail, status: e.status);
      case 'http404':
        return AppException('llmUrl', '翻译网关地址不存在（404）', detail: e.detail, status: e.status);
      case 'http429':
        return AppException('llmRate', '翻译网关被限流（429），请稍后再试', detail: e.detail, status: e.status, retryable: true);
      case 'http524':
        return AppException('llmSlow', '网关处理超时（524），这次内容太多，请稍后再试', detail: e.detail, status: e.status);
      case 'timeout':
        return AppException('llmSlow', 'AI 响应超时，请稍后再试', detail: e.detail, status: e.status, retryable: true);
      case 'badJson':
      case 'emptyBody':
        return AppException('llmFormat', '模型返回的不是预期内容', detail: e.detail);
    }
    if (e.retryable) {
      return AppException(e.code, '${e.message}（网关：${_cfg.gatewayBase}）', detail: e.detail, status: e.status, retryable: true);
    }
    return e;
  }

  Future<dynamic> structured(String system, String user, {double temperature = 0.3, String? model}) async {
    final raw = await chat(system, '$user\n只输出 JSON，不要任何解释或 Markdown 代码块。', temperature: temperature, model: model);
    return _decode(raw);
  }

  dynamic _decode(String raw) {
    final start = raw.indexOf(RegExp(r'[\{\[]'));
    final end = raw.lastIndexOf(RegExp(r'[\}\]]'));
    final text = (start >= 0 && end > start) ? raw.substring(start, end + 1) : raw;
    try {
      return jsonDecode(text);
    } on FormatException catch (e) {
      // 模型偶尔会夹带解释文字或输出被截断：转成可展示的中文错误，
      // 否则页面只能显示「操作失败」，用户和排查都拿不到线索。
      final head = raw.length > 120 ? '${raw.substring(0, 120)}…' : raw;
      throw AppException('llmFormat', '模型返回的 JSON 不完整，请重试', detail: '${e.message} · $head');
    }
  }
}
