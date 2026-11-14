import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_fonts.dart';
import 'tts_voices.dart';

class AppConfigService extends ChangeNotifier {
  SharedPreferences? _prefs;
  bool _secureOk = !Platform.environment.containsKey('FLUTTER_TEST');
  bool _darkMode = true;
  // 阅读设置（对齐 store.reader）
  double _fontSize = 18;
  double _lineHeight = 1.8;

  /// 正文字体（kReaderFonts 的 id，空串 = 系统默认）与段间距（dp）。
  String _readerFont = kReaderDefaultFont;
  double _paraSpacing = 18;

  /// 阅读页配色：`night` 低眩光深色 / `paper` 暖纸色。
  String _readerTheme = 'night';

  // 朗读：Edge 神经音色 id 与语速（语速 0.7-1.3，1.0 为原速）。
  String _ttsVoice = kEdgeDefaultVoice;
  double _ttsSpeed = 1.0;

  // 云端配置：地址与密钥全部内置在 App 里，用户既看不到也改不了（「我的」页已无服务配置入口）。
  // 密钥不落源码，构建时用 --dart-define 注入，见 tool/release.ps1。
  String _articleApiBase = defaultArticleApiBase;
  String _gatewayBase = defaultGatewayBase;
  String _gatewayModel = defaultGatewayModel;
  String _articleApiKey = defaultArticleApiKey;
  String _gatewayKey = defaultGatewayKey;

  static const defaultArticleApiBase = 'https://read.tu.lztfirefly.top';
  static const defaultGatewayBase = 'https://gateway.lztfirefly.top';
  static const defaultGatewayModel = 'tencent/Hunyuan-MT-7B';

  /// 总结/长难句解析这类「理解型」任务的模型（源码常量，不进 setRemote/prefs）。
  /// 默认模型混元 MT-7B 是翻译特化模型，做总结与语法拆解偏弱；
  /// 网关 `/v1/chat/completions` 支持在请求体里透传任意 SiliconFlow 的 model。
  static const defaultGatewayAnalysisModel = 'Qwen/Qwen3-8B';

  /// 构建时注入：`--dart-define=ARTICLE_API_KEY=xxx` / `--dart-define=GATEWAY_KEY=xxx`。
  /// 未注入时为空串，App 取不到云端数据——这是源码裸构建的预期行为。
  static const defaultArticleApiKey = String.fromEnvironment('ARTICLE_API_KEY');
  static const defaultGatewayKey = String.fromEnvironment('GATEWAY_KEY');

  static const _kArticleApiBase = 'article_api_base';
  static const _kGatewayBase = 'gateway_base';
  static const _kGatewayModel = 'gateway_model';

  // 密钥：secure 侧带 _v1 后缀，明文侧（Keystore 不可用时的兜底）不带。
  static const _sArticleApiKey = 'article_api_key_v1';
  static const _kArticleApiKey = 'article_api_key';
  static const _sGatewayKey = 'gateway_key_v1';
  static const _kGatewayKey = 'gateway_key';

  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions());

  bool get darkMode => _darkMode;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  String get readerFont => _readerFont;
  double get paraSpacing => _paraSpacing;
  String get readerTheme => _readerTheme;
  String get ttsVoice => _ttsVoice;
  double get ttsSpeed => _ttsSpeed;

  /// 云端文章接口（列表 / 详情 / 缓存正文）。
  String get articleApiBase => _articleApiBase;
  String get gatewayBase => _gatewayBase;
  String get gatewayModel => _gatewayModel;
  String get articleApiKey => _articleApiKey;
  String get gatewayKey => _gatewayKey;

  /// 写入云端服务配置（接口地址 / 模型名 / 密钥）。传 null 表示不改该项。
  Future<void> setRemote({
    String? articleApiBase,
    String? gatewayBase,
    String? gatewayModel,
    String? articleApiKey,
    String? gatewayKey,
  }) async {
    if (articleApiBase != null && articleApiBase.trim().isNotEmpty) {
      _articleApiBase = articleApiBase.trim();
      await _prefs?.setString(_kArticleApiBase, _articleApiBase);
    }
    if (gatewayBase != null && gatewayBase.trim().isNotEmpty) {
      _gatewayBase = gatewayBase.trim();
      await _prefs?.setString(_kGatewayBase, _gatewayBase);
    }
    if (gatewayModel != null && gatewayModel.trim().isNotEmpty) {
      _gatewayModel = gatewayModel.trim();
      await _prefs?.setString(_kGatewayModel, _gatewayModel);
    }
    if (articleApiKey != null) {
      _articleApiKey = articleApiKey;
      await _writeSecret(_sArticleApiKey, _kArticleApiKey, articleApiKey);
    }
    if (gatewayKey != null) {
      _gatewayKey = gatewayKey;
      await _writeSecret(_sGatewayKey, _kGatewayKey, gatewayKey);
    }
    notifyListeners();
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _darkMode = _prefs!.getBool('dark_mode') ?? true;
    _fontSize = _prefs!.getDouble('reader_fontSize') ?? 18;
    _lineHeight = _prefs!.getDouble('reader_lineHeight') ?? 1.8;
    _readerFont = normalizeReaderFont(_prefs!.getString('reader_font'));
    _paraSpacing = (_prefs!.getDouble('reader_paraSpacing') ?? 18).clamp(10.0, 32.0);
    _readerTheme = _prefs!.getString('reader_theme') ?? 'night';
    // 老用户本地存的是网关音色 id（alex/bella…），这里归一成 Edge 音色，否则合成必然失败。
    _ttsVoice = normalizeEdgeVoice(_prefs!.getString('tts_voice'));
    _ttsSpeed = (_prefs!.getDouble('tts_speed') ?? 1.0).clamp(0.7, 1.3);

    _articleApiBase = _prefs!.getString(_kArticleApiBase) ?? defaultArticleApiBase;
    _gatewayBase = _prefs!.getString(_kGatewayBase) ?? defaultGatewayBase;
    _gatewayModel = _prefs!.getString(_kGatewayModel) ?? defaultGatewayModel;
    // 内置密钥优先。只有源码裸构建（未注入）时才回落到本机存的旧值。
    _articleApiKey = defaultArticleApiKey.isNotEmpty
        ? defaultArticleApiKey
        : (await _readSecret(_sArticleApiKey, _kArticleApiKey) ?? '');
    _gatewayKey = defaultGatewayKey.isNotEmpty
        ? defaultGatewayKey
        : (await _readSecret(_sGatewayKey, _kGatewayKey) ?? '');
  }

  Future<String?> _readSecret(String secureKey, String legacyKey) async {
    if (_secureOk) {
      try {
        final v = await _secure.read(key: secureKey);
        if (v != null) return v;
      } catch (_) {
        _secureOk = false;
      }
    }
    return _prefs?.getString(legacyKey);
  }

  Future<void> _writeSecret(String secureKey, String legacyKey, String value) async {
    if (_secureOk) {
      try {
        await _secure.write(key: secureKey, value: value);
        await _prefs?.remove(legacyKey);
        return;
      } catch (_) {
        _secureOk = false;
      }
    }
    await _prefs?.setString(legacyKey, value);
  }

  Future<void> setDarkMode(bool v) async {
    _darkMode = v;
    await _prefs!.setBool('dark_mode', v);
    notifyListeners();
  }

  Future<void> setReader({double? fontSize, double? lineHeight, String? font, double? paraSpacing, String? theme}) async {
    if (fontSize != null) {
      _fontSize = fontSize;
      await _prefs!.setDouble('reader_fontSize', fontSize);
    }
    if (lineHeight != null) {
      _lineHeight = lineHeight;
      await _prefs!.setDouble('reader_lineHeight', lineHeight);
    }
    if (font != null) {
      // 允许传空串（回到系统默认），但要归一成合法 id。
      _readerFont = normalizeReaderFont(font);
      await _prefs!.setString('reader_font', _readerFont);
    }
    if (paraSpacing != null) {
      _paraSpacing = paraSpacing.clamp(10.0, 32.0);
      await _prefs!.setDouble('reader_paraSpacing', _paraSpacing);
    }
    if (theme != null && theme.isNotEmpty) {
      _readerTheme = theme;
      await _prefs!.setString('reader_theme', theme);
    }
    notifyListeners();
  }

  /// 朗读音色 / 语速（Edge TTS）。语速夹在 0.7-1.3，避免用户调出极端值。
  Future<void> setTts({String? voice, double? speed}) async {
    if (voice != null && voice.isNotEmpty) {
      _ttsVoice = normalizeEdgeVoice(voice);
      await _prefs!.setString('tts_voice', _ttsVoice);
    }
    if (speed != null) {
      _ttsSpeed = speed.clamp(0.7, 1.3);
      await _prefs!.setDouble('tts_speed', _ttsSpeed);
    }
    notifyListeners();
  }
}
