# 应用内更新协议（ToneUp Read）

本文件是 `ToneUp_read` 与 `ToneUpWord` 共用的更新契约。两个应用各自使用**固定的**发布资产名
（read 为 `ToneUP-read.apk`，word 为 `ToneUpWord.apk`），但 `version.json` 字段名、版本比较
规则、镜像列表顺序必须保持一致；只允许 UI、语言和 APK 文件名层面的差异。

## 1. Release 资产（名字一个字都不能改）

每个正式 Release 必须包含且只依赖这两个资产：

| 资产 | 用途 |
| --- | --- |
| `ToneUP-read.apk` | 应用内下载的安装包（**固定名**） |
| `version.json` | 版本元数据（**固定名**） |

客户端不使用 `api.github.com`，只请求：

```
https://github.com/hbt123-123/ToneUp_read/releases/latest/download/version.json
https://github.com/hbt123-123/ToneUp_read/releases/latest/download/ToneUP-read.apk
```

`latest` 只认 **Published** 的 Release；草稿和 Pre-release 不算。

## 2. version.json 字段

```json
{
  "version": "3.6.0",
  "versionCode": 360,
  "url": "https://github.com/hbt123-123/ToneUp_read/releases/latest/download/ToneUP-read.apk",
  "sha256": "<小写 64 位十六进制>",
  "size": 56752404,
  "notes": "更新说明"
}
```

- 文件由 `tool/release.ps1` 生成，字段与 Word 端逐字一致。
- `url` 必须是 `https://`；下载完成后整包校验 SHA-256，不匹配立即删除，绝不安装。
- 未知字段会被忽略，便于以后扩展。

## 3. 版本规则

- Release tag 必须等于 `v<versionName>`，例如 `v3.6.0`。
- `versionCode == major*100 + minor*10 + patch`，例如 `3.6.0 → 360`；
  `tool/release.ps1` 会校验，不一致直接报错。
- 判断更新顺序：`versionCode` 优先，缺失时回退三段语义版本，仍无法判断则不提示。
- 「跳过此版本」按 `versionCode` 记录；只有更高的版本才会重新提示。

## 4. 检查与下载

- 启动时静默检查，成功拿到 manifest 后 24 小时内不再自动检查；手动检查不受限。
- **只有成功的检查才写入时间戳**：失败会在下次启动重试，不会空等一整天。
- 直连 GitHub 失败时按 `lib/services/update_service.dart` 的镜像列表尝试最多 3 个；
  失败线路冷却 30 分钟，成功线路会被记住。
- 下载写入 `<versionCode>.apk.part`，长度即断点；校验通过后改名为 `<versionCode>.apk`，
  只有这个文件能交给系统安装器。SHA-256 只负责完整性，防篡改的最终边界是 Android 的
  「同签名覆盖安装」——新包必须与已安装版本使用同一签名密钥。
- 安装走系统安装器，不存在静默安装。

## 5. 发布清单

```powershell
# 1. 改 pubspec.yaml 的 version（X.Y.Z+BUILD，BUILD 必须等于 major*100+minor*10+patch）
# 2. 更新 release-notes.md
# 3. 发布前自检
flutter analyze
flutter test
# 4. 构建并生成发布物（脚本自动注入密钥）
powershell -ExecutionPolicy Bypass -File tool\release.ps1 -AppVersion 3.6.0 -Tag
# 5. git push origin main v3.6.0
# 6. GitHub Release: tag v3.6.0，上传 dist\ToneUP-read.apk + dist\version.json，Publish
# 7. 手工同步 README「下载与版本」表格（脚本不会改 README）
```

完整的 GitHub 上传/验收步骤见 [RELEASE_UPLOAD.md](RELEASE_UPLOAD.md)。

发布后自检：

- 打开 `https://github.com/hbt123-123/ToneUp_read/releases/latest/download/version.json`，
  确认 `versionCode` 比现网安装包大；
- 用旧版本 App 打开「我的 → 检查更新」，确认能看到新版本与更新说明；
- 安装后再次检查，应显示“已是最新版本”。
