import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:toneup_read/services/update_service.dart';

enum UpdatePhase {
  idle,

  /// 正在检查远端
  checking,

  /// 已是最新
  latest,

  /// 有新版待用户决定（静默下载失败后的手动兜底）
  available,

  /// 后台静默下载中
  downloading,

  /// 校验中（下载完的 sha256 比对阶段）
  verifying,

  /// 安装包已就绪待安装（下载完自动提示；取消后本会话不再弹，红点保留）
  ready,

  /// 已交给系统安装器
  installing,

  /// 失败（[error] 有说明）
  failed,
}

/// 更新流程的界面状态机：策略（每天一次检查、发现新版静默下载、只弹一次、
/// 跳过此版本）都在这里，页面只负责渲染 [phase]。
class UpdateController extends ChangeNotifier {
  final UpdateService service;
  UpdateController(this.service);

  UpdatePhase phase = UpdatePhase.idle;
  UpdateInfo? info;
  String? error;
  int received = 0;
  int total = 0;
  String installedLabel = '';

  /// 本地已就绪的安装包 versionCode（0 = 无）。
  int _readyVc = 0;

  double get progress => total > 0 ? (received / total).clamp(0, 1) : 0;

  /// 自动检查是否过期（每天最多一次）。
  static const _autoInterval = Duration(hours: 24);

  Future<void> init() async {
    final v = await service.installedVersion();
    installedLabel = 'v$v';
    // 恢复本地下载状态：上次会话下完没装 → 直接进入就绪态；下载到一半 → 交给
    // download() 里按 part 文件长度断点续传。失败静默吞掉（临时目录可能不可用）。
    if (phase == UpdatePhase.idle) {
      try {
        await service.pruneLocal();
        final ready = await service.readyFile();
        if (ready != null) {
          if (await service.ignoredVersionCode() == ready.vc) {
            // 这个包已被「跳过此版本」：别再留几十 MB，也别再进入就绪态。
            await service.discardReady();
          } else {
            _readyVc = ready.vc;
            phase = UpdatePhase.ready;
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<bool> _dueForAutoCheck() async {
    final last = await service.lastCheckMs();
    if (last == 0) return true;
    return DateTime.now().millisecondsSinceEpoch - last >= _autoInterval.inMilliseconds;
  }

  /// 启动时的静默检查：失败**不打扰**用户，也不写入「已检查」时间，
  /// 下次打开 App 会立刻重试（镜像失败有 30 分钟冷却，不会连续打同一个坏线路）。
  /// 发现新版且未被「跳过此版本」→ 直接转入后台静默下载。
  Future<void> autoCheck() async {
    if (!await _dueForAutoCheck()) return;
    await _check(manual: false);
    if (phase == UpdatePhase.available && info != null) {
      unawaited(backgroundDownload());
    }
  }

  /// 手动检查：失败要说清原因，且不受「每天一次」限制。
  Future<void> checkNow() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    if (phase == UpdatePhase.checking ||
        phase == UpdatePhase.downloading ||
        phase == UpdatePhase.verifying) {
      return;
    }
    final prev = phase; // 失败回退用：已恢复的就绪态不能被一次失败的检查冲掉
    phase = UpdatePhase.checking;
    error = null;
    notifyListeners();
    // 手动检查时给动效一点最短展示时间，避免瞬间闪完看不出发生了什么。
    final started = DateTime.now();
    final remote = await service.fetch();
    if (manual) {
      final elapsed = DateTime.now().difference(started);
      const minShow = Duration(milliseconds: 600);
      if (elapsed < minShow) await Future<void>.delayed(minShow - elapsed);
    }
    if (remote == null) {
      // 静默检查失败不打扰：保持原状态（已恢复的就绪包不能因为检查失败而丢）。
      // markChecked 只在成功分支写：失败一旦写入时间戳，会把重试推迟一整天。
      phase = manual ? UpdatePhase.failed : prev;
      error = manual ? '检查失败，换个线路再试试' : null;
      notifyListeners();
      return;
    }
    await service.markChecked();
    final ignored = await service.ignoredVersionCode();
    final newer = await service.hasUpdate(remote);
    if (_readyVc >= remote.versionCode) {
      // 本地就绪包就是（或高于）远端目标版本：保持就绪，顺便补充展示信息
      info = remote;
      phase = UpdatePhase.ready;
    } else if (newer && remote.versionCode != ignored) {
      info = remote;
      phase = UpdatePhase.available;
    } else {
      info = remote;
      phase = UpdatePhase.latest;
    }
    notifyListeners();
  }

  /// 首次发现某个版本才弹一次卡片，之后只留入口行上的红点。
  Future<bool> shouldPrompt() async {
    if (phase != UpdatePhase.available) return false;
    final vc = info?.versionCode ?? 0;
    if (vc == 0) return false;
    if (await service.promptedVersionCode() == vc) return false;
    await service.markPrompted(vc);
    return true;
  }

  /// 稍后：只关卡片，不改变状态。available 保留入口行红点，ready 保留已就绪，
  /// 用户下次可从「我的」继续；只有「跳过此版本」才会真正抑制。
  void dismiss() {
    notifyListeners();
  }

  /// 跳过此版本：除非出现更高版本号，否则不再提示；本地已就绪的包一并清掉。
  Future<void> skipVersion() async {
    final vc = info?.versionCode ?? 0;
    if (vc > 0) {
      await service.ignoreVersion(vc);
      if (_readyVc == vc) {
        await service.discardReady();
        _readyVc = 0;
      }
    }
    phase = UpdatePhase.idle;
    notifyListeners();
  }

  /// 静默后台下载：成功 → 就绪；失败静默回退 available（红点保留），不打扰用户。
  Future<void> backgroundDownload() async {
    final target = info;
    if (target == null) return;
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.verifying) return;
    phase = UpdatePhase.downloading;
    error = null;
    received = 0;
    total = target.size;
    notifyListeners();
    try {
      await service.download(
        target,
        onProgress: (got, sum) {
          received = got;
          total = sum;
          notifyListeners();
        },
      );
      _readyVc = target.versionCode;
      phase = UpdatePhase.ready;
    } catch (_) {
      phase = UpdatePhase.available; // 静默失败：回到手动模式，等下次启动断点续传
    }
    notifyListeners();
  }

  /// 手动「立即更新」：就绪包直接装；否则下载（自动断点续传）→ 校验 → 唤起安装器。
  Future<void> downloadAndInstall() async {
    if (phase == UpdatePhase.ready) {
      await installReady();
      return;
    }
    final target = info;
    if (target == null) return;
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.verifying) return;
    phase = UpdatePhase.downloading;
    error = null;
    received = 0;
    total = target.size;
    notifyListeners();
    try {
      await service.download(
        target,
        onProgress: (got, sum) {
          received = got;
          total = sum;
          notifyListeners();
        },
      );
      _readyVc = target.versionCode;
      phase = UpdatePhase.verifying;
      notifyListeners();
      await installReady();
    } on UpdateChecksumException {
      phase = UpdatePhase.failed;
      error = '安装包校验未通过，已丢弃（可换个线路重试）';
      notifyListeners();
    } catch (e) {
      phase = UpdatePhase.failed;
      error = '下载失败：$e';
      notifyListeners();
    }
  }

  /// 安装已就绪的包：未知来源未授权时先引导用户去系统设置。
  Future<void> installReady() async {
    if (phase == UpdatePhase.installing) return;
    final ready = await service.readyFile();
    if (ready == null) {
      phase = UpdatePhase.failed;
      error = '安装包不存在，请重新下载';
      notifyListeners();
      return;
    }
    phase = UpdatePhase.verifying;
    notifyListeners();
    if (!await service.canInstallPackages()) {
      final granted = await service.requestInstallPermission();
      if (!granted) {
        phase = UpdatePhase.failed;
        error = '需要在系统设置里允许本应用「安装未知应用」';
        notifyListeners();
        return;
      }
    }
    final err = await service.install(ready.file);
    if (err != null) {
      phase = UpdatePhase.failed;
      error = err;
    } else {
      phase = UpdatePhase.installing;
    }
    notifyListeners();
  }
}
