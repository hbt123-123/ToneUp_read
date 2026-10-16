import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:toneup_read/services/db_service.dart';
import 'package:toneup_read/services/http_service.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/llm_service.dart';
import 'package:toneup_read/services/tts_service.dart';
import 'package:toneup_read/services/translate_service.dart';
import 'package:toneup_read/services/vocab_service.dart';
import 'package:toneup_read/services/curate_service.dart';
import 'package:toneup_read/services/update_controller.dart';
import 'package:toneup_read/services/update_service.dart';
import 'package:toneup_read/services/word_service.dart';
import 'package:toneup_read/services/dict_service.dart';
import 'package:toneup_read/services/remote_article_service.dart';

final dbProvider = Provider((ref) => DbService());
/// HttpService 不持有配置（请求头由调用方传入），无需随 appConfig 重建；
/// 也要避免改成 watch appConfig —— 每次 notify 会连带重建服务链并泄漏未 close 的 http.Client。
final httpProvider = Provider((ref) => HttpService());
final appConfigProvider = ChangeNotifierProvider<AppConfigService>((ref) => AppConfigService());
final llmProvider = Provider((ref) => LlmService(ref.watch(httpProvider), ref.read(appConfigProvider)));
final ttsProvider = Provider((ref) => TtsService());
final translateProvider = Provider((ref) => TranslateService(ref.watch(llmProvider)));
final vocabProvider = Provider((ref) => VocabService(ref.watch(dbProvider), ref.watch(llmProvider)));
final updateServiceProvider = Provider((ref) => UpdateService());
/// 应用内更新的界面状态（检查 / 下载 / 安装），由「我的 → 关于」与更新卡片共用。
final updateProvider = ChangeNotifierProvider<UpdateController>((ref) => UpdateController(ref.watch(updateServiceProvider)));
final curateProvider = Provider((ref) => CurateService(ref.watch(llmProvider)));
/// 网关词典（/dict + /en）：点词词卡的结构化数据源。
final dictProvider = Provider((ref) => DictService(ref.watch(httpProvider), ref.read(appConfigProvider)));
/// 云端文章接口 + 本地缓存层（列表/详情/正文落库/标题中译批量）。
final remoteArticleProvider =
    Provider((ref) => RemoteArticleService(ref.watch(dbProvider), ref.watch(httpProvider), ref.read(appConfigProvider), ref.watch(translateProvider)));
final wordProvider = Provider((ref) => WordService(ref.watch(dbProvider), ref.watch(dictProvider), ref.watch(translateProvider)));

class ThemeModeNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(appConfigProvider).darkMode;
  void set(bool v) {
    ref.read(appConfigProvider).setDarkMode(v);
    state = v;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, bool>(ThemeModeNotifier.new);

/// 当前底部 Tab 索引（0 首页 / 1 词汇 / 2 句子 / 3 我的）。
class TabIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final tabIndexProvider = NotifierProvider<TabIndexNotifier, int>(TabIndexNotifier.new);

/// 通用「数据变更信号」：数值每次 +1 即通知监听者刷新。
///
/// 用途：跨页面写入的数据（词汇 / 云端文章缓存），其所在页面是
/// IndexedStack 常驻 Tab，不会重建，必须靠信号驱动刷新。
class RevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// 词汇变更（阅读中点词、复习评分、增删词汇）。
final vocabRevisionProvider = NotifierProvider<RevisionNotifier, int>(RevisionNotifier.new);

/// 云端文章缓存（列表 / 缓存正文 / 标题中译）变更信号：
/// 云端列表拉取或 `cacheArticle` 落库后调用 `bump()`，首页等监听页刷新。
final articleRevisionProvider = NotifierProvider<RevisionNotifier, int>(RevisionNotifier.new);
