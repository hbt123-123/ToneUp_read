import 'package:flutter_test/flutter_test.dart';
import 'package:toneup_read/services/app_config_service.dart';
import 'package:toneup_read/services/tts_service.dart';
import 'package:toneup_read/services/tts_voices.dart';

/// 朗读服务单测：只覆盖**纯逻辑**（切句 / 参数校验 / 空播放器的生命周期）。
///
/// 不打网络、不碰平台通道：云端分段靠真实 mp3 才能验证，本机兜底要真机
/// 才能验证，两者都放集成测试；这里保证「不联网也能构造、stop 不炸」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('splitSentences', () {
    test('普通多句文本按句号切开', () {
      const text = 'Reading English every day improves your vocabulary. '
          'It also trains your ears to catch the natural rhythm. '
          'Keep a notebook beside you while you read.';
      final segs = TtsService.splitSentences(text);
      expect(segs, hasLength(3));
      expect(segs[0], 'Reading English every day improves your vocabulary.');
      expect(segs[1], 'It also trains your ears to catch the natural rhythm.');
      expect(segs[2], 'Keep a notebook beside you while you read.');
    });

    test('小数点与缩写不会把句子切碎', () {
      // "3.5" 里的点后面不是空白，不该当成句末。
      expect(
        TtsService.splitSentences('The price rose to 3.5 dollars in one week.'),
        ['The price rose to 3.5 dollars in one week.'],
      );
      // "Dr." 会被切开，但随后的短碎片会合并回来。
      expect(
        TtsService.splitSentences('Dr. Smith arrived at nine.'),
        ['Dr. Smith arrived at nine.'],
      );
    });

    test('过短的碎片并入相邻句', () {
      final head = TtsService.splitSentences(
        'Yes. This sentence is long enough to stand alone as a whole.',
      );
      expect(head, hasLength(1));
      expect(head.single, startsWith('Yes. '));

      final tail = TtsService.splitSentences(
        'This sentence is long enough to stand alone as a whole. Indeed.',
      );
      expect(tail, hasLength(1));
      expect(tail.single, endsWith(' Indeed.'));
    });

    test('不换行空格与多余空白归一成单个空格', () {
      final segs = TtsService.splitSentences('Hello\u00A0world.  It   works.');
      expect(segs, ['Hello world. It works.']);
    });

    test('超长句按 600 字符上限二次切分', () {
      final long = '${List.filled(150, 'word').join(' ')}.';
      expect(long.length, greaterThan(TtsService.maxSegmentChars));

      final segs = TtsService.splitSentences(long);
      expect(segs.length, greaterThanOrEqualTo(2));
      for (final s in segs) {
        expect(s.length, lessThanOrEqualTo(TtsService.maxSegmentChars),
            reason: '单段不能超过合成分片上限：${s.length}');
        expect(s, isNot(startsWith(' ')));
        expect(s, isNot(endsWith(' ')));
      }
      // 切分只丢空白，不能丢内容。
      expect(segs.join(' '), long);
    });

    test('空白文本返回空列表', () {
      expect(TtsService.splitSentences(''), isEmpty);
      expect(TtsService.splitSentences('  \n\t\u00A0 '), isEmpty);
    });
  });

  group('播放生命周期', () {
    test('空文本直接抛异常（沿用旧契约）', () async {
      final tts = TtsService(AppConfigService());
      await expectLater(tts.speak('   '), throwsA(isA<Exception>()));
      expect(tts.isPlaying, isFalse);
      expect(tts.segment.value, -1);
    });

    test('构造 + stop 不会创建播放器，也不抛 MissingPluginException', () async {
      final tts = TtsService(AppConfigService());
      expect(tts.isPlaying, isFalse);
      expect(tts.segment.value, -1);

      // 播放器/本机引擎都是懒创建的：这里没有平台通道也必须立刻返回。
      await tts.stop().timeout(const Duration(seconds: 2));
      // 幂等：没在播的时候再停一次也得干净返回。
      await tts.stop().timeout(const Duration(seconds: 2));
      expect(tts.isPlaying, isFalse);
      expect(tts.segment.value, -1);
    });
  });

  group('edgeRateFor 语速映射', () {
    test('原速与两端档位', () {
      expect(TtsService.edgeRateFor(1.0), '+0%');
      expect(TtsService.edgeRateFor(0.7), '-30%');
      expect(TtsService.edgeRateFor(1.3), '+30%');
    });

    test('中间档位四舍五入到整数百分比', () {
      expect(TtsService.edgeRateFor(0.85), '-15%');
      expect(TtsService.edgeRateFor(1.15), '+15%');
    });

    test('所有档位都符合 edge_tts 的 rate 校验格式', () {
      // edge_tts 的构造函数只接受 ^[+-]\d+%$ 形式的 rate。
      final re = RegExp(r'^[+-]\d+%$');
      for (final speed in const [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3]) {
        final rate = TtsService.edgeRateFor(speed);
        expect(re.hasMatch(rate), isTrue, reason: '$speed → $rate 不符合 rate 格式');
      }
    });
  });

  group('音色 id 归一', () {
    test('旧网关音色 / 空值 / null 全部回落到默认音色', () {
      expect(normalizeEdgeVoice('alex'), kEdgeDefaultVoice);
      expect(normalizeEdgeVoice(''), kEdgeDefaultVoice);
      expect(normalizeEdgeVoice(null), kEdgeDefaultVoice);
    });

    test('已知 Edge 音色原样保留', () {
      expect(normalizeEdgeVoice('en-GB-SoniaNeural'), 'en-GB-SoniaNeural');
    });

    test('内置音色表完整且默认音色排第一', () {
      expect(kEdgeVoices, hasLength(8));
      for (final v in kEdgeVoices) {
        expect(v[0], endsWith('Neural'));
      }
      expect(kEdgeVoices.first[0], kEdgeDefaultVoice);
      expect(isKnownEdgeVoice(kEdgeDefaultVoice), isTrue);
    });
  });
}
