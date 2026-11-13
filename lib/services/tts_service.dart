import 'dart:async';
import 'dart:io';

import 'package:edge_tts/edge_tts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'app_config_service.dart';
import 'tts_voices.dart';

/// 朗读服务：**Edge 神经音色直连为主 + 本机系统 TTS 兜底**。
///
/// 为什么不用 `flutter_tts.speak(整篇文章)` 直接念：
/// 1. 系统离线音色机械、断句生硬，长文本还会撞上 Android 引擎的长度上限
///    （表现为中途静音或直接结束）；
/// 2. 整篇一次合成没法做「跟读高亮」——拿不到「现在念到第几句」。
///
/// 现在的链路：正文切句 → 每句用 `edge_tts` 的 `Communicate` 直连 Microsoft
/// Edge 朗读服务合成一段 mp3（落到临时目录）→ 用 `just_audio` 的
/// [ConcatenatingAudioSource] 把**已合成的段**串起来播 → 后台继续按需合成
/// 后续句段，边播边往队列尾部追加。
///
/// 这条链路不需要任何密钥（Edge 的公共朗读接口）：
/// 1. 音色是 Edge 的神经音色，明显比离线引擎自然；
/// 2. 逐句合成才有 `currentIndex`，才能映射回「第几句」做跟读高亮；
/// 3. 单句合成失败只影响衔接，不会让整篇卡死。
///
/// 兜底原则：**绝不让用户听不到声音**。缺少临时目录、`getTemporaryDirectory`
/// 抛错、合成超时、断网、WebSocket 报错、播放器起播失败——任何一环失败都会
/// 回落到 [FlutterTts]，并从当前句继续把剩下的内容念完。
///
/// 取消语义（重要取舍）：`stop()` 只自增 [_gen]，**不强杀**正在进行的
/// `save()`（edge_tts 内部没法取消一次已经在跑的合成）。所以：
/// * 进行中的合成不会出声——结果会被 `gen != _gen` 丢弃，不入队、不播放；
/// * 已经落盘的半成品文件，在下一轮 [_playEdge] 开头整目录清空时自愈。
///
/// 播放器与 [FlutterTts] 都**懒创建**：widget 测试会 `TtsService(cfg)` 后直接
/// `stop()`，此时构造里不能碰任何平台通道（否则 MissingPluginException）。
class TtsService {
  TtsService(this._cfg);

  final AppConfigService _cfg;

  /// 播放状态（true=正在朗读）。UI 监听它，而不是自己猜。
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  /// 当前朗读到的**句子下标**（调用方 `speakSegments` 传进来的那份句表的下标），
  /// 空闲/停止时为 -1。UI 用它做跟读高亮。
  ///
  /// 注意：超长句会被二次切分成多段，但这里仍报「原句」下标，
  /// 保证高亮不会因为内部切分而错位。
  final ValueNotifier<int> segment = ValueNotifier<int>(-1);

  /// 单段文本上限。600 字符约 100 词。
  ///
  /// Edge 内部会按 4096 字节再自动分块，这里限长不是为了接口上限，而是为了
  /// 「跟读高亮 + 增量合成队列」的粒度：段太大则首句要等很久、后面也没法
  /// 边播边补。
  static const int maxSegmentChars = 600;

  /// 过短的碎片（"Yes." "OK."）单独成段听起来像卡带，并入相邻句。
  static const int _minSegmentChars = 24;

  /// 起播准备超时：首批合成完到播放器真正就绪，别让用户干等。
  static const Duration _cloudPrepTimeout = Duration(seconds: 20);

  /// 单段合成超时。edge_tts 没有内置超时，网络卡住时 `save()` 会一直挂着，
  /// 必须自己套一层，否则「正在生成语音…」会永远转下去。
  static const Duration _synthTimeout = Duration(seconds: 30);

  /// 首批只合成 2 段：够起播就行。整篇合完要几十秒，用户等不起。
  static const int _firstBatch = 2;

  /// 队列只领先当前播放位置 3 段。堆太多会白占临时目录空间，
  /// 也让「中途改语速」这类后续能力没法提前收手。
  static const int _maxLead = 3;

  /// 试听用固定句子（短、含常见音素，能听出音色差异）。
  static const String previewLine =
      'Hello, this is how I will read your article. Let us begin.';

  /// 句末标点后紧跟的引号/括号，切句时要一并吞掉。
  static const String _closers = '"\'”’)]';

  AudioPlayer? _player;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<ProcessingState>? _stateSub;
  StreamSubscription<PlaybackEvent>? _eventSub;

  FlutterTts? _localTts;

  /// 本机英文音色只挑一次（`getVoices` 在部分机型上较慢），挑好后复用。
  bool _localVoiceReady = false;

  /// 取消令牌：每次 speak/stop 自增。异步链上任何一环比对自己的 gen
  /// 与 [_gen] 是否一致，就知道自己是否已被新的请求取代（避免双重朗读）。
  int _gen = 0;

  /// 当前是否真的在走 Edge 播放（用于区分「播完」与「被 stop 掉」）。
  bool _cloudActive = false;

  /// 最近一次请求的完整分片表，播放期报错时从这里续读剩余内容。
  List<_Piece> _activePieces = const <_Piece>[];

  /// 当前这一轮 Edge 播放的运行态（队列、偏移、补合成进度）。`stop()` 置空后，
  /// 所有监听器/后台任务都会因为拿不到它而安静退出。
  _Run? _run;

  bool get isPlaying => playing.value;

  /// 朗读纯文本：内部切句后从头开始（单条词/短语也走这里）。
  Future<void> speak(String text) async {
    final input = text.trim();
    if (input.isEmpty) throw Exception('没有可朗读的文本');
    await speakSegments(splitSentences(input));
  }

  /// 朗读调用方已切好的句子表（阅读器自己按段落/句子切开，便于和原文对齐）。
  ///
  /// [start] 是 [texts] 里的起始句下标。空串元素会被丢弃。
  Future<void> speakSegments(List<String> texts, {int start = 0}) async {
    final pieces = _pieces(texts);
    if (pieces.isEmpty) return;
    await stop();
    final gen = _gen;
    _activePieces = pieces;
    final from = _indexForSource(pieces, start);
    // 先只报「要念第几句」（高亮先亮起来），playing 等音频真的就绪才置 true：
    // UI 用它区分「正在生成语音…」与「朗读中」，否则合成那几秒会假装已在播。
    segment.value = pieces[from].source;

    // Edge 不需要密钥：先试神经音色，失败（断网/超时/目录不可用）再走本机。
    final ok = await _playEdge(
      pieces,
      from,
      gen,
      normalizeEdgeVoice(_cfg.ttsVoice),
    );
    if (ok) return; // 云端已开播（或已被 stop 取代，都无需兜底）
    if (gen != _gen) return; // 合成期间用户点了停止，别再补一段本机朗读
    await _playLocal(pieces, from, gen);
  }

  /// 试听某音色：固定一句，语速用配置值；失败同样回落本机朗读。
  Future<void> preview(String voiceId) async {
    await stop();
    final gen = _gen;
    final pieces = _pieces(<String>[previewLine]);
    if (pieces.isEmpty) return;
    _activePieces = pieces;
    segment.value = 0;
    // 传空就沿用设置里的音色（未知值会被 normalize 折回默认音色）。
    final voice = normalizeEdgeVoice(
      voiceId.trim().isEmpty ? _cfg.ttsVoice : voiceId,
    );

    final ok = await _playEdge(pieces, 0, gen, voice);
    if (ok) return;
    if (gen != _gen) return;
    await _playLocal(pieces, 0, gen);
  }

  /// 停止：安全、幂等、绝不抛异常。
  ///
  /// 没有播放器/没有本机引擎时直接返回（widget 测试就靠这一点）。
  /// 这里**不挂 .timeout**：`AudioPlayer.stop()` 与 `FlutterTts.stop()` 都是
  /// 一次平台调用，正常毫秒级返回；挂定时器反而给测试留下 pending timer。
  Future<void> stop() async {
    _gen++;
    // 先断掉「这一轮」的身份：后台补合成任务与播放器监听器都以它为准，
    // 置空后它们即使还在跑也只会静默退出，绝不会再出声。
    _run = null;
    _activePieces = const <_Piece>[];
    _cloudActive = false;
    playing.value = false;
    segment.value = -1;

    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
    }
    final local = _localTts;
    if (local != null) {
      try {
        await local.stop();
      } catch (_) {}
    }
  }

  /// 释放播放器与订阅（provider 不销毁时可不调用；调用后仍可再次朗读）。
  Future<void> dispose() async {
    await stop();
    final player = _player;
    _player = null;
    final subs = <StreamSubscription<dynamic>?>[
      _indexSub,
      _stateSub,
      _eventSub,
    ];
    _indexSub = null;
    _stateSub = null;
    _eventSub = null;
    for (final sub in subs) {
      if (sub == null) continue;
      try {
        await sub.cancel();
      } catch (_) {}
    }
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  // ================= Edge 播放 =================

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    // 当前段变化 → 换算回调用方的句子下标。
    // 队列是从 `run.from` 起算的偏移，所以必须加偏移；直接拿 i 当句下标会错位。
    // 只在 Edge 真正在播时更新：stop()/播完后播放器仍可能吐索引，别让它把 -1 盖掉。
    _indexSub = player.currentIndexStream.listen((i) {
      final run = _run;
      if (run == null || !_cloudActive) return;
      if (i == null || i < 0) return;
      final idx = run.from + i;
      if (idx < 0 || idx >= run.pieces.length) return;
      segment.value = run.pieces[idx].source;
    });
    _stateSub = player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onQueueCompleted();
    });
    // 播放期错误（断网/解码失败/音频焦点被抢）走兜底，不要停在半路静音。
    _eventSub = player.playbackEventStream.listen(
      (_) {},
      onError: (Object _, StackTrace __) => unawaited(_onPlaybackError()),
    );
    return player;
  }

  /// 当前播放到的**队列下标**（不是句下标）。未就绪时按 0 处理。
  ///
  /// 单独包一层的理由：`currentIndex` 在 just_audio 里是 `int?`，这里统一成
  /// 非空的 int，省得每个调用点都判空。
  static int _currentQueueIndex(AudioPlayer player) {
    final Object? raw = player.currentIndex;
    return raw is int && raw >= 0 ? raw : 0;
  }

  /// 用 Edge 合成并起播。返回 true 表示云端已接管（含「合成期间被 stop 取代」），
  /// 返回 false 表示**尚未开播**，调用方应从原句下标走本机兜底。
  Future<bool> _playEdge(
    List<_Piece> pieces,
    int from,
    int gen,
    String voice,
  ) async {
    final firstFiles = <String>[];
    try {
      // 清掉上一轮残留（被 stop 掉的合成不可取消，可能还会往目录里写文件；
      // 这里先清、下一轮再清，残留文件总能自愈）。
      await _clearEdgeDir();
      if (gen != _gen) return true;

      // 1) 首批只合成 2 段，够起播就行。
      final firstEnd = from + _firstBatch > pieces.length
          ? pieces.length
          : from + _firstBatch;
      for (var i = from; i < firstEnd; i++) {
        if (gen != _gen) return true;
        final file = await _synthFile(pieces[i].text, voice, gen, i);
        if (gen != _gen) return true;
        firstFiles.add(file);
      }
      if (firstFiles.isEmpty) return false;

      // 2) 串成队列。useLazyPreparation 让播放器只预取下一段，不用等整篇。
      final player = _ensurePlayer();
      final source = ConcatenatingAudioSource(
        useLazyPreparation: true,
        children: <AudioSource>[
          for (final f in firstFiles) AudioSource.uri(Uri.file(f)),
        ],
      );
      await player
          .setAudioSource(
            source,
            initialIndex: 0,
            initialPosition: Duration.zero,
          )
          .timeout(_cloudPrepTimeout);
      if (gen != _gen) return true; // 准备期间被 stop()/新请求取代

      final run = _Run(
        gen: gen,
        pieces: pieces,
        from: from,
        voice: voice,
        source: source,
        queued: firstFiles.length,
      );
      _run = run;
      _cloudActive = true;
      // 音频真的就绪了才报 playing：UI 的「正在生成语音…」靠这个信号收尾。
      playing.value = true;
      // 3) play() 的 Future 要等这一整条队列播完才完成，不能 await（会卡住调用方）。
      // 起播就抛（音频焦点被抢/解码失败）时立刻走兜底，别留下 playing 卡 true 的假象。
      unawaited(
        player.play().catchError((Object _) {
          unawaited(_onPlaybackError());
        }),
      );
      // 4) 后台补合成剩余段，边播边往队列尾部追加。
      unawaited(_pipeline(run, gen));
      return true;
    } catch (_) {
      // 首批就失败：清掉半成品，交调用方从原句下标走本机兜底。
      if (_run?.gen == gen) _run = null;
      if (gen == _gen) {
        _cloudActive = false;
        playing.value = false;
      }
      for (final f in firstFiles) {
        try {
          File(f).deleteSync(recursive: true);
        } catch (_) {}
      }
      final player = _player;
      // 只有「这一轮还是最新请求」时才停播放器：否则会误停新一轮的播放。
      if (player != null && gen == _gen) {
        try {
          await player.stop();
        } catch (_) {}
      }
      return false;
    }
  }

  /// 后台补合成：每合成完一段就 `add` 进队列（just_audio 0.9 支持播放中改队列），
  /// 并把队列领先量压在 [_maxLead] 段以内。
  Future<void> _pipeline(_Run run, int gen) async {
    for (var i = run.from + run.queued; i < run.pieces.length; i++) {
      if (gen != _gen || !identical(_run, run)) return;
      final player = _player;
      if (player != null) {
        // 领先太多就等一等，避免一口气把整篇合成写满临时目录。
        while (run.queued - _currentQueueIndex(player) > _maxLead) {
          if (gen != _gen || !identical(_run, run)) return;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }

      final String file;
      try {
        file = await _synthFile(run.pieces[i].text, run.voice, gen, i);
      } catch (_) {
        // 半路合成失败：从「正在播的那一段」起换本机引擎念完，别停成静音。
        await _handoffToLocal(gen, run);
        return;
      }
      if (gen != _gen || !identical(_run, run)) return; // 合成期间被 stop 掉了

      try {
        await run.source.add(AudioSource.uri(Uri.file(file)));
      } catch (_) {
        await _handoffToLocal(gen, run);
        return;
      }
      run.queued++;
      if (run.awaitingMore) {
        // 队列刚才被播空（completed），现在有新段了：seek 过去把它接上。
        await _resumeQueue(run, gen, run.queued - 1);
      }
    }
    if (gen != _gen || !identical(_run, run)) return;
    run.synthDone = true;
    // 边界情况：最后一段刚入队、队列在此前已被播空。
    if (run.awaitingMore) {
      await _resumeQueue(run, gen, run.queued - 1);
    }
  }

  /// 队列被播空后又补上了新段：seek 到新段并续播。
  Future<void> _resumeQueue(_Run run, int gen, int index) async {
    if (gen != _gen || !identical(_run, run)) return;
    final player = _player;
    if (player == null) return;
    try {
      await player.seek(Duration.zero, index: index);
    } catch (_) {
      // seek 失败（队列还没刷新出这一项等）：别干等着，直接换本机念完，
      // 否则会停在 playing=true 却没声音的状态。
      await _handoffToLocal(gen, run);
      return;
    }
    if (gen != _gen || !identical(_run, run)) return;
    run.awaitingMore = false;
    unawaited(
      player.play().catchError((Object _) {
        unawaited(_onPlaybackError());
      }),
    );
  }

  /// `processingState == completed` 的处理。
  ///
  /// 关键：队列被播空并不等于「念完了」——后面可能还有没合成的段。
  void _onQueueCompleted() {
    if (!_cloudActive) return;
    final run = _run;
    if (run == null) {
      unawaited(_finish());
      return;
    }
    if (!run.synthDone) {
      // 只是暂时播空：挂个标记，等 [_pipeline] 追加完再 seek 续播。
      run.awaitingMore = true;
      return;
    }
    unawaited(_finish());
  }

  /// 播完（队列里最后一段也播完了）：复位状态，并把播放器 stop 回开头。
  Future<void> _finish() async {
    if (!_cloudActive) return;
    _cloudActive = false;
    _run = null;
    playing.value = false;
    segment.value = -1;
    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
    }
  }

  /// 播放期出错：停掉云端，从当前句开始用本机引擎把剩下的念完。
  Future<void> _onPlaybackError() async {
    if (!_cloudActive) return;
    await _handoffToLocal(_gen, _run);
  }

  /// 云端半路失效（合成失败/播放报错）：从「正在播的那一段」起换本机引擎念完。
  ///
  /// 先取 `currentIndex` 再 stop——stop 之后索引会被复位，取晚了就会从头念。
  Future<void> _handoffToLocal(int gen, _Run? run) async {
    if (!_cloudActive) return;
    final player = _player;
    final cur = player == null ? 0 : _currentQueueIndex(player);

    // 先同步把身份清掉：阻止后台 pipeline 继续入队，也让重复的错误回调直接返回。
    _cloudActive = false;
    if (run == null || identical(_run, run)) _run = null;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
    }

    final pieces = run?.pieces ?? _activePieces;
    if (gen != _gen || pieces.isEmpty) return;
    var from = run == null ? 0 : run.from + cur;
    // 越界就夹到合法范围。**不要**改用 `_indexForSource`：它按 `source`（调用方
    // 句下标）匹配，而这里的 `from` 是 pieces 分片下标，两套索引空间不能混用。
    if (from < 0) from = 0;
    if (from >= pieces.length) from = pieces.length - 1;
    // playing 保持 true：换引擎的瞬间 UI 不该闪一下「已停止」。
    await _playLocal(pieces, from, gen);
  }

  /// Edge 语速参数：App 的 0.7–1.3 线性映射成 `-30%`…`+30%`。
  ///
  /// Edge 只接受 `^[+-]\d+%$`，格式不对 `Communicate` 会直接抛 ArgumentError，
  /// 所以这里统一算出字符串、且非负值必须带 `+`。
  static String edgeRateFor(double speed) {
    final pct = ((speed - 1.0) * 100).round().clamp(-50, 100).toInt();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  /// 合成一段到临时文件，返回文件路径。
  Future<String> _synthFile(
    String text,
    String voice,
    int gen,
    int index,
  ) async {
    final dir = await _edgeDir();
    // 文件名带上 gen：被 stop 掉的旧合成即使晚到，也不会覆盖新一轮的文件。
    final path = '${dir.path}${Platform.pathSeparator}${gen}_$index.mp3';
    final comm = Communicate(
      text: text,
      voice: voice,
      rate: edgeRateFor(_cfg.ttsSpeed),
    );
    // 没有内置超时；网络卡住时必须由我们兜底。
    await comm.save(path).timeout(_synthTimeout);
    return path;
  }

  /// 临时目录 `…/tts_edge/`：合成出来的 mp3 只服务于当前这一轮朗读。
  static Future<Directory> _edgeDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}${Platform.pathSeparator}tts_edge');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 清空临时目录。`getTemporaryDirectory` 在极端情况下会抛，
  /// 这里吞掉：真正的失败由随后的 [_synthFile] 暴露，让调用方走本机兜底。
  static Future<void> _clearEdgeDir() async {
    try {
      final dir = await _edgeDir();
      for (final f in dir.listSync()) {
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ================= 本机兜底 =================

  Future<void> _playLocal(List<_Piece> pieces, int from, int gen) async {
    final tts = await _ensureLocalVoice();
    if (gen != _gen) return;
    playing.value = true;
    for (var i = from; i < pieces.length; i++) {
      if (gen != _gen) return; // 被 stop()/新请求取代
      segment.value = pieces[i].source;
      final text = pieces[i].text;
      try {
        // awaitSpeakCompletion(true) 下 speak() 念完才返回；
        // 再套一层保守超时，防止个别引擎漏回调把循环永久卡住。
        await tts.speak(text).timeout(
          Duration(seconds: 10) + Duration(milliseconds: 90 * text.length),
        );
      } catch (_) {
        if (gen != _gen) return;
        // 单句失败就跳过，继续下一句——比整篇静音好。
      }
    }
    if (gen != _gen) return;
    playing.value = false;
    segment.value = -1;
  }

  Future<FlutterTts> _ensureLocalVoice() async {
    final cached = _localTts;
    if (cached != null && _localVoiceReady) {
      // 语速随时可改，每次朗读前同步一下（音色仍然只挑一次）。
      try {
        await cached.setSpeechRate(_localRate(_cfg.ttsSpeed));
      } catch (_) {}
      return cached;
    }
    final tts = cached ?? FlutterTts();
    _localTts = tts;
    try {
      await tts.awaitSpeakCompletion(true);
    } catch (_) {}
    try {
      await tts.setPitch(1.0);
    } catch (_) {}
    try {
      await tts.setVolume(1.0);
    } catch (_) {}
    try {
      await tts.setSpeechRate(_localRate(_cfg.ttsSpeed));
    } catch (_) {}
    try {
      // getVoices 在个别机型/引擎上会长时间不回调：超时就走默认英文，
      // 不能让「正在生成语音…」卡死（用户至少还能听到本机朗读）。
      final raw = await tts.getVoices.timeout(const Duration(seconds: 3));
      final best = raw is List ? _pickEnglishVoice(raw) : null;
      final name = best?['name'] ?? '';
      final locale = best?['locale'] ?? '';
      if (name.isNotEmpty) {
        await tts.setVoice(<String, String>{
          'name': name,
          'locale': locale.isEmpty ? 'en-US' : locale,
        });
      } else {
        await tts.setLanguage('en-US');
      }
      _localVoiceReady = true;
    } catch (_) {
      // 老机型/无 Google TTS 时 getVoices 可能直接抛（或超时），退回默认英文。
      // 失败也标记 ready：否则每次朗读都要白等一次 3s 超时。
      try {
        await tts.setLanguage('en-US');
      } catch (_) {}
      _localVoiceReady = true;
    }
    return tts;
  }

  /// App 语速 1.0 ≈ 常速；而 flutter_tts 在 Android 上 0.5 才接近常速
  /// （1.0 明显过快），所以这里按 0.5 的基准线性映射。
  static double _localRate(double speed) =>
      (0.5 * speed).clamp(0.05, 1.0).toDouble();

  /// 从 `getVoices()` 里挑最像「自然英文女声」的那个：
  /// 先按 locale 排（en-US 优先，其次其它 en-*），再给带
  /// network / neural / female 字样的音色加分（Google TTS 的离线音色最机械）。
  static Map<String, String>? _pickEnglishVoice(List<dynamic> voices) {
    Map<String, String>? best;
    var bestScore = 0;
    for (final v in voices) {
      if (v is! Map) continue;
      final m = <String, String>{};
      v.forEach((k, val) => m['$k'] = '$val');
      final locale = (m['locale'] ?? '').toLowerCase().replaceAll('_', '-');
      if (!locale.startsWith('en')) continue;
      final name = (m['name'] ?? '').toLowerCase();
      var score = locale == 'en-us' ? 30 : 10;
      if (name.contains('network')) score += 4;
      if (name.contains('neural')) score += 4;
      if (name.contains('female')) score += 2;
      if (score > bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best;
  }

  // ================= 切句（纯函数，单测覆盖） =================

  /// 把正文切成句子。
  ///
  /// 规则刻意保持简单：按 `.` `!` `?`（以及中文全角句末符）切，但要求标点后
  /// 是空白或文本结尾——这样 `3.5`、`e.g.x` 这类内部点号不会被误切。
  /// 缩写（Dr. / Mr.）仍会被切开，但随后的短碎片合并会把它们黏回去。
  /// 最后把超过 [maxSegmentChars] 的句子二次切分（优先标点、其次空格）。
  static List<String> splitSentences(String text) {
    final norm = _normalize(text);
    if (norm.isEmpty) return const <String>[];

    final raw = <String>[];
    var startIdx = 0;
    for (var i = 0; i < norm.length; i++) {
      if (!'.!?。！？'.contains(norm[i])) continue;
      var j = i + 1;
      while (j < norm.length && _closers.contains(norm[j])) {
        j++;
      }
      final atEnd = j >= norm.length;
      if (!atEnd && norm[j] != ' ') continue; // 小数点 / 句中缩写里的点
      final piece = norm.substring(startIdx, j).trim();
      if (piece.isNotEmpty) raw.add(piece);
      startIdx = j;
      i = j;
    }
    final tail = norm.substring(startIdx).trim();
    if (tail.isNotEmpty) raw.add(tail);
    if (raw.isEmpty) return const <String>[];

    // 合并过短碎片：优先并到前一句；首句过短则并到后一句。
    final merged = <String>[];
    for (final s in raw) {
      if (merged.isNotEmpty && s.length < _minSegmentChars) {
        merged[merged.length - 1] = '${merged.last} $s';
      } else {
        merged.add(s);
      }
    }
    if (merged.length > 1 && merged.first.length < _minSegmentChars) {
      merged[1] = '${merged.first} ${merged[1]}';
      merged.removeAt(0);
    }

    final out = <String>[];
    for (final s in merged) {
      out.addAll(_capSegment(s));
    }
    return out;
  }

  /// 单段超过 [maxSegmentChars] 时二次切分：先在标点处断，退而求其次在空格处断。
  static List<String> _capSegment(String text) {
    if (text.length <= maxSegmentChars) return <String>[text];
    final out = <String>[];
    var rest = text;
    while (rest.length > maxSegmentChars) {
      var cut = -1;
      for (var i = maxSegmentChars; i > maxSegmentChars ~/ 2; i--) {
        if ('.!?;:,'.contains(rest[i - 1])) {
          cut = i;
          break;
        }
      }
      if (cut < 0) {
        final sp = rest.lastIndexOf(' ', maxSegmentChars);
        cut = sp > maxSegmentChars ~/ 2 ? sp : maxSegmentChars;
      }
      final head = rest.substring(0, cut).trim();
      if (head.isNotEmpty) out.add(head);
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// 折行、连续空格、不换行空格统统归一成单个空格，切句才好判。
  static String _normalize(String text) =>
      text.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 调用方句表 → 内部合成分片（保留 source 下标用于跟读高亮）。
  List<_Piece> _pieces(List<String> texts) {
    final out = <_Piece>[];
    for (var i = 0; i < texts.length; i++) {
      final t = _normalize(texts[i]);
      if (t.isEmpty) continue;
      for (final part in _capSegment(t)) {
        out.add(_Piece(part, i));
      }
    }
    return out;
  }

  /// 找第一个 `source >= start` 的分片下标；越界就退到最后一句话。
  static int _indexForSource(List<_Piece> pieces, int start) {
    final target = start < 0 ? 0 : start;
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i].source >= target) return i;
    }
    return pieces.length - 1;
  }
}

/// 一个待合成的分片：`text` 真正发给 Edge，`source` 是调用方句表里的原句下标。
class _Piece {
  const _Piece(this.text, this.source);

  final String text;
  final int source;
}

/// 一轮 Edge 播放的完整运行态。
///
/// 之所以要单独持有 `pieces` / `from`，是因为播放器队列的下标是
/// **从 `from` 起算的偏移**：`queueIndex + from` 才是 `pieces` 的下标，
/// `pieces[...].source` 才是调用方的句下标。
class _Run {
  _Run({
    required this.gen,
    required this.pieces,
    required this.from,
    required this.voice,
    required this.source,
    required this.queued,
  });

  /// 创建它的那一次请求的取消令牌；`stop()` 之后 [_gen] 会变，据此判失效。
  final int gen;

  final List<_Piece> pieces;

  /// 本轮从 `pieces` 的哪一段开始播（对应调用方的起始句）。
  final int from;

  final String voice;

  /// 正在播放的串联队列。补合成时直接往它尾部 `add`。
  final ConcatenatingAudioSource source;

  /// 已经合成并 add 进队列的段数。
  int queued;

  /// 剩余段是否已全部合成完（含「本来就没有剩余」）。
  bool synthDone = false;

  /// 队列被播空、但后面还有段没合成——别当成整篇播完。
  bool awaitingMore = false;
}
