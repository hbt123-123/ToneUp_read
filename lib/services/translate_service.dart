import 'package:toneup_read/services/llm_service.dart';

/// 单引擎翻译：只走翻译网关（`LlmService` → `${gatewayBase}/v1/chat/completions`）。
/// 早期的百度 / MyMemory / LibreTranslate / 自定义接口回落链已随云端化移除。
class TranslateService {
  final LlmService _llm;

  /// 单引擎：网关地址 / 密钥 / 模型都由 `_llm` 自行读取配置。
  TranslateService(this._llm);

  /// 翻译文本。失败直接抛错（由调用方决定是否回落），不吞错。
  Future<String> translate(String text, {String from = 'en', String to = 'zh'}) async {
    if (text.trim().isEmpty) return '';
    const system = 'You are a translator. Output only the translation, '
        'never any explanation, notes, labels or markdown.';
    final user = 'Translate the following text from $from to $to.\n'
        '<<<\n$text\n>>>';
    return (await _llm.chat(system, user)).trim();
  }
}
