import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toneup_read/services/update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _apkUrl = 'https://github.com/hbt123-123/ToneUp_read/releases/latest/download/ToneUP-read.apk';

Map<String, Object?> _payload({
  String version = '3.6.0',
  Object? versionCode = 360,
  String url = _apkUrl,
  String sha256 = 'abc',
  Object? size = 100,
  String? notes = '更新说明',
}) =>
    {'version': version, 'versionCode': versionCode, 'url': url, 'sha256': sha256, 'size': size, 'notes': notes};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    UpdateService.offline = false;
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('go_update_test');
    // path_provider 的平台通道在单测里不存在，直接给个临时目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => tmp.path);
  });
  tearDown(() {
    UpdateService.offline = true;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('UpdateInfo 解析（坏 JSON 不能让检查更新崩掉）', () {
    test('完整合法', () {
      final i = UpdateInfo.tryParse(_payload(sha256: 'AB12'))!;
      expect(i.version, '3.6.0');
      expect(i.versionCode, 360);
      expect(i.size, 100);
      expect(i.notes, '更新说明');
      expect(i.sha256, 'ab12', reason: 'sha 统一小写再比');
    });

    test('缺字段/类型不对的处理', () {
      expect(UpdateInfo.tryParse(_payload(versionCode: '360'))!.versionCode, 360, reason: '字符串数字也认');
      expect(UpdateInfo.tryParse(_payload(versionCode: null))!.versionCode, 0);
      expect(UpdateInfo.tryParse(_payload(notes: null))!.notes, '');
      expect(UpdateInfo.tryParse(_payload(url: 'x')), isNull, reason: '非绝对 URL');
      expect(UpdateInfo.tryParse({'version': 1, 'url': _apkUrl, 'sha256': 'a'}), isNull);
      expect(UpdateInfo.tryParse('not a map'), isNull);
      expect(UpdateInfo.tryParse(null), isNull);
    });

    test('url 白名单：http 与陌生域名一律拒绝（防代理把用户引到钓鱼站）', () {
      expect(UpdateInfo.tryParse(_payload(url: 'http://github.com/x')), isNull);
      expect(UpdateInfo.tryParse(_payload(url: 'https://evil.com/ToneUP-read.apk')), isNull);
      expect(UpdateInfo.tryParse(_payload(url: 'https://github.com.evil.com/a.apk')), isNull);
      expect(UpdateService.urlAllowed('https://gh-proxy.com/https://x'), isTrue, reason: '内置镜像域名可以');
      expect(UpdateService.urlAllowed('https://objects.githubusercontent.com/a'), isTrue);
    });
  });

  group('版本比较', () {
    bool newer(int rc, String rv, int ic, String iv) =>
        UpdateService.isNewer(remoteCode: rc, remoteVersion: rv, installedCode: ic, installedVersion: iv);

    test('优先比 versionCode', () {
      expect(newer(351, '3.5.1', 350, '3.5.0'), isTrue);
      expect(newer(350, '3.5.0', 350, '3.5.0'), isFalse);
      expect(newer(349, '3.4.9', 350, '3.5.0'), isFalse);
    });

    test('缺字段时回退比三段版本号，容忍 V3.0 / v3.5 老写法', () {
      expect(newer(0, 'V3.6', 0, '3.5.0'), isTrue);
      expect(newer(0, '3.5', 0, '3.5.0'), isFalse, reason: '缺的段补 0');
      expect(newer(0, 'v3.0', 0, '3.5.0'), isFalse);
      expect(newer(0, '3.5.1', 350, '3.5.0'), isTrue, reason: '只有远端缺 code 也能比');
    });

    test('都读不出来就不提示（宁可漏报，不要无限提示更新）', () {
      expect(newer(0, 'abc', 0, '3.5.0'), isFalse);
      expect(newer(0, '3.5.0', 0, ''), isFalse);
    });
  });

  group('端点策略', () {
    test('直连成功：不打反代，且记住直连', () async {
      final hits = <String>[];
      final s = UpdateService(client: MockClient((req) async {
        hits.add(req.url.toString());
        return http.Response.bytes(utf8.encode(jsonEncode(_payload())), 200);
      }));
      final info = await s.fetch();
      expect(info!.versionCode, 360);
      expect(hits, [UpdateService.jsonUrl]);
      expect((await SharedPreferences.getInstance()).getString('update_ok_host'), '');
    });

    test('直连失败则走反代，并按 path-prefix 拼接', () async {
      final hits = <String>[];
      final s = UpdateService(client: MockClient((req) async {
        hits.add(req.url.toString());
        if (req.url.host == 'github.com') return http.Response('nope', 500);
        return http.Response.bytes(utf8.encode(jsonEncode(_payload())), 200);
      }));
      final info = await s.fetch();
      expect(info, isNotNull);
      expect(hits.length, 2);
      expect(hits[1], startsWith('https://${UpdateService.mirrorHosts.first}/https://github.com/'));
      expect((await SharedPreferences.getInstance()).getString('update_ok_host'), UpdateService.mirrorHosts.first);
    });

    test('记忆的端点排最前', () async {
      SharedPreferences.setMockInitialValues({'update_ok_host': 'tvv.tw'});
      final hits = <String>[];
      final s = UpdateService(client: MockClient((req) async {
        hits.add(req.url.host);
        return http.Response.bytes(utf8.encode(jsonEncode(_payload())), 200);
      }));
      await s.fetch();
      expect(hits.first, 'tvv.tw');
    });

    test('冷却中的端点被跳过；只试 3 个就放弃，网络层失败才记冷却', () async {
      final until = DateTime.now().add(const Duration(minutes: 20)).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({'update_dead_hosts': jsonEncode({'': until})});
      final hits = <String>[];
      final s = UpdateService(client: MockClient((req) async {
        hits.add(req.url.host);
        throw http.ClientException('network down');
      }));
      expect(await s.fetch(), isNull);
      expect(hits.contains('github.com'), isFalse, reason: '直连在冷却期，不该再试');
      expect(hits.length, 3, reason: '冷启动探测预算 3 个');
      final dead = jsonDecode((await SharedPreferences.getInstance()).getString('update_dead_hosts')!) as Map;
      expect(dead.containsKey(hits.first), isTrue, reason: '网络失败的端点进冷却');
    });

    test('404 不算端点故障（通道是活的，只是远端还没发布），不进冷却', () async {
      final s = UpdateService(client: MockClient((req) async => http.Response('not found', 404)));
      expect(await s.fetch(), isNull);
      final raw = (await SharedPreferences.getInstance()).getString('update_dead_hosts');
      expect(raw ?? '{}', '{}', reason: '拿到 HTTP 响应就说明通道可用，不该被冷落 30 分钟');
    });

    test('坏 JSON 视为该端点不可用，换下一个', () async {
      final hits = <String>[];
      final s = UpdateService(client: MockClient((req) async {
        hits.add(req.url.host);
        if (req.url.host == 'github.com') return http.Response('not json', 200);
        return http.Response.bytes(utf8.encode(jsonEncode(_payload())), 200);
      }));
      expect(await s.fetch(), isNotNull);
      expect(hits.length, 2);
    });
  });

  group('下载与校验', () {
    final apk = utf8.encode('fake apk bytes');
    final good = sha256.convert(apk).toString();

    UpdateInfo _info({String? sha, int? size, int vc = 360}) => UpdateInfo(
          version: '3.6.0',
          versionCode: vc,
          url: _apkUrl,
          sha256: sha ?? good,
          size: size ?? apk.length,
          notes: '',
        );

    File partFile(int vc) => File('${tmp.path}/update/$vc.apk.part');
    File apkFile(int vc) => File('${tmp.path}/update/$vc.apk');

    test('sha256 一致才转正为 <vc>.apk', () async {
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      final f = await s.download(_info());
      expect(await f.readAsBytes(), apk);
      expect(f.path, endsWith('360.apk'), reason: '校验通过才从 part 转正');
      expect(partFile(360).existsSync(), isFalse);
    });

    test('sha256 不匹配：删文件 + 抛异常（绝不交给安装器）', () async {
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      await expectLater(s.download(_info(sha: 'f' * 64)), throwsA(isA<UpdateChecksumException>()));
      expect(apkFile(360).existsSync(), isFalse, reason: '坏包必须删掉');
      expect(partFile(360).existsSync(), isFalse);
      final dir = Directory('${tmp.path}/update');
      expect(dir.listSync(), isEmpty, reason: '不留任何半成品');
    });

    test('已就绪的包跨会话复用，不再发请求', () async {
      final dir = Directory('${tmp.path}/update');
      dir.createSync(recursive: true);
      await apkFile(360).writeAsBytes(apk);
      var hits = 0;
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        hits++;
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      final progress = <int>[];
      final f = await s.download(_info(), onProgress: (got, total) => progress.add(got));
      expect(hits, 0, reason: '就绪包直接复用');
      expect(await f.readAsBytes(), apk);
      expect(progress, [apk.length], reason: '复用时报告一次完成进度');
    });
  });

  group('断点续传', () {
    final apk = utf8.encode('0123456789abcdef'); // 16 字节，前 10 + 后 6 两段
    final good = sha256.convert(apk).toString();

    UpdateInfo _info({int vc = 360}) => UpdateInfo(
          version: '3.6.0',
          versionCode: vc,
          url: _apkUrl,
          sha256: good,
          size: apk.length,
          notes: '',
        );

    Future<void> seedPart(int vc, List<int> bytes) async {
      final dir = Directory('${tmp.path}/update');
      dir.createSync(recursive: true);
      await File('${dir.path}/$vc.apk.part').writeAsBytes(bytes);
    }

    test('part 存在：带 Range 头，206 响应追加拼接', () async {
      await seedPart(360, apk.sublist(0, 10));
      final ranges = <String?>[];
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        ranges.add(req.headers['range']);
        return http.StreamedResponse(Stream.value(apk.sublist(10)), 206, contentLength: apk.length - 10);
      }));
      final f = await s.download(_info());
      expect(ranges, ['bytes=10-'], reason: '从 part 长度处续传');
      expect(await f.readAsBytes(), apk);
      expect(f.path, endsWith('360.apk'));
    });

    test('端点不支持 Range（回 200 全量）：丢旧 part 重头下，结果仍正确', () async {
      await seedPart(360, apk.sublist(0, 10));
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      final f = await s.download(_info());
      expect(await f.readAsBytes(), apk, reason: '200 视为不支持续传，全量重下');
      expect(f.readAsBytesSync().length, apk.length, reason: '不能把旧 part 拼在新全量后面');
    });

    test('流被提前掐断：换端点从断点接着下', () async {
      final ranges = <String?>[];
      var call = 0;
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        ranges.add(req.headers['range']);
        call++;
        if (call == 1) {
          // 直连：声明 16 字节但只给 10 个就正常收尾（模拟被掐断）
          return http.StreamedResponse(Stream.value(apk.sublist(0, 10)), 200, contentLength: apk.length);
        }
        // 镜像：从断点续上
        return http.StreamedResponse(Stream.value(apk.sublist(10)), 206, contentLength: apk.length - 10);
      }));
      final f = await s.download(_info());
      expect(ranges, [isNull, 'bytes=10-'], reason: '第一次无 part，第二次从断点续传');
      expect(await f.readAsBytes(), apk);
    });

    test('版本隔离：不同 versionCode 各自维护 part', () async {
      await seedPart(360, apk.sublist(0, 10));
      final ranges = <String?>[];
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        ranges.add(req.headers['range']);
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      await s.download(_info(vc: 361));
      expect(ranges, [isNull], reason: '361 没有自己的 part，不带 Range，不沾 360 的断点');
      expect(File('${tmp.path}/update/360.apk.part').existsSync(), isTrue, reason: '360 的 part 不被动');
      expect(File('${tmp.path}/update/361.apk').existsSync(), isTrue);
    });

    test('part 比预期还长：视为脏数据重头下', () async {
      await seedPart(360, [...apk, ...apk]);
      final ranges = <String?>[];
      final s = UpdateService(client: MockClient.streaming((req, bodyStream) async {
        ranges.add(req.headers['range']);
        return http.StreamedResponse(Stream.value(apk), 200, contentLength: apk.length);
      }));
      final f = await s.download(_info());
      expect(ranges, [isNull], reason: '脏 part 已删，从头下不带 Range');
      expect(await f.readAsBytes(), apk);
    });
  });

  group('本地更新包状态', () {
    test('readyFile 取 versionCode 最大且高于已安装的就绪包，忽略 part', () async {
      final dir = Directory('${tmp.path}/update');
      dir.createSync(recursive: true);
      await File('${dir.path}/350.apk').writeAsBytes([1]);
      await File('${dir.path}/360.apk').writeAsBytes([2]);
      await File('${dir.path}/370.apk.part').writeAsBytes([3]);
      final s = UpdateService(client: MockClient((req) async => http.Response('', 404)));
      final ready = await s.readyFile();
      expect(ready, isNotNull);
      expect(ready!.vc, 360, reason: '370 只有 part，不算就绪；350/360 里取最大');
    });

    test('discardReady 只清成品，保留续传进度的 part', () async {
      final dir = Directory('${tmp.path}/update');
      dir.createSync(recursive: true);
      await File('${dir.path}/350.apk').writeAsBytes([1]);
      await File('${dir.path}/360.apk.part').writeAsBytes([2]);
      final s = UpdateService(client: MockClient((req) async => http.Response('', 404)));
      await s.discardReady();
      expect(File('${dir.path}/350.apk').existsSync(), isFalse);
      expect(File('${dir.path}/360.apk.part').existsSync(), isTrue, reason: 'part 是续传进度，不随成品清');
    });
  });
}
