<div align="center">

---


## 下载与版本

默认下载 **v1.0.6**：当前可用版本，文章接口与翻译网关的密钥已内置，装上即用；自带应用内自动更新。v0.1 是早期构建（未内置密钥，功能不可用），仅作历史归档。

| 版本 | 状态 | 下载 |
| --- | --- | --- |
| **v1.0.6** | 当前版本，推荐 | [下载 APK](https://github.com/hbt123-123/ToneUp_read/releases/latest/download/ToneUP-read.apk) |
| v1.0.5 | 历史版本，建议升级 | [Release v1.0.5](https://github.com/hbt123-123/ToneUp_read/releases/tag/v1.0.5) |
| v1.0.4 | 历史版本，建议升级 | [Release v1.0.4](https://github.com/hbt123-123/ToneUp_read/releases/tag/v1.0.4) |
| v0.3 | 历史版本，建议升级 | [Release v0.3](https://github.com/hbt123-123/ToneUp_read/releases/tag/v0.3) |
| v0.2 | 历史版本，建议升级 | [Release v0.2](https://github.com/hbt123-123/ToneUp_read/releases/tag/v0.2) |
| v0.1 | 历史归档，功能不可用 | [Release v0.1](https://github.com/hbt123-123/ToneUp_read/releases/tag/v0.1) |

- 全部版本见 [Releases](https://github.com/hbt123-123/ToneUp_read/releases)。
- 应用内「我的 → 检查更新」按 `releases/latest` 的固定资产名（`ToneUP-read.apk` / `version.json`）判断新版本。

---

## 功能

底部共 3 个 Tab：**首页 / 收藏 / 我的**。

- **云端文章流（首页）**

  - 从自建文章接口拉取列表，卡片展示中文标题（客户端机翻并落库缓存）、来源、发布时间与词数。
  - 来源筛选、下拉刷新、滚动到底自动加载更多（每页 20 条）；已缓存文章带「已缓存」小标。
  - 顶部「继续阅读」卡：直接回到上次读到的段落。
  - 点卡片自动缓存正文后进入阅读器；拉取失败自动回落本地已缓存列表，离线也能读缓存过的文章。
- **沉浸式阅读器**

  - 点正文空白进入沉浸模式；顶栏可一键开关朗读、AI 精选与阅读设置。
  - 字号 / 行距 / 段距 / 正文字体可调并本地记忆；阅读页提供「夜读 / 纸色」两套配色，与 App 主题相互独立。
  - **点词查词**：就地在词旁弹出词卡，词典网关 `/dict` + `/en` 双源合成结构化数据——音标、发音、中英多义项（带词性）、词形变化、考试标签、柯林斯星级与建议词。
  - **长按整句**取句，工具栏「选择」可点选多词；选区条提供 朗读 / 查询 / 翻译 / 收藏。
  - 句子翻译与短语释义走翻译网关（查询文本含空格自动走「短语」分支，不打词典）。
  - **AI 精选**：`LLM` 把长文压成精读版，可随时切回原文、重新精选或删除，并给出「段落 / 字数」精简摘要。
  - **朗读**：客户端直连 Edge 神经音色逐句合成播放，内置 8 种英文音色、语速可调；任何环节失败自动回落系统 `TTS`。
  - **打开原文**：正文未缓存或需要对照原站时，一键在浏览器打开文章原始链接。
- **收藏**

  - 单词与句子合并在同一页，分段管理。
  - 单词：搜索、全部 / 单词 / 短语筛选、发音、出处回原文、删除、清空。
  - 句子：搜索、翻译（结果落库，重启后直接显示）、朗读、复制、回到原文、`LLM` 语法 / 语块拆解、删除。
  - **AI 整理**：从收藏页顶栏次级入口进入，把查询过的生词按主题聚类，补全词性、释义、词族与例句。
  - **生词导出**：一键复制「半角逗号 + 空格」分隔的英文词表（可直接粘贴进常见背单词 App），或调用系统分享。
- **我的**

  - 无需配置：文章接口与翻译网关的地址、密钥、模型全部内置，装上即用。
  - 外观：深色 / 浅色模式（默认浅色）。
  - 数据管理：清除缓存（文章与词典，保留收藏）/ 清空全部数据。
  - 关于：检查更新，应用内下载并安装新版本。
- **数据与隐私**

  无账号、无登录。接口密钥编译在 APK 里，源码与仓库中都查不到；设置项存本机 `shared_preferences`；文章缓存、生词、句子与阅读数据全部只在本机数据库。

---

## 技术栈

- `Flutter 3.47` / `Dart 3.13`（仅 Android，`applicationId` 为 `top.toneup.read`）
- `Riverpod 3`（Provider + Notifier 变更信号）
- `sqflite`（本地数据：文章缓存 / 词汇 / 句子 / 词典缓存 / 中文标题）
- `http`（网络层，可注入 `Client`，测试用官方 `MockClient`）
- `edge_tts` + `just_audio`（Edge 神经音色合成与队列播放）、`flutter_tts`（合成失败时的系统 TTS 兜底）
- `shared_preferences`（普通配置）、`flutter_secure_storage`（密钥存 Android Keystore）
- `share_plus`（分享导出）、`url_launcher`（打开原文）
- `package_info_plus` + `open_filex` + `permission_handler`（应用内更新）
- `crypto`、`flutter_lints` + `flutter_test` + `integration_test`

设计走自建 token 体系（`lib/theme/go_tokens.dart` 的 `Go.*`），组件集中在 `lib/widgets/`，页面只做组合。

---

## 项目结构

```text
lib/
  main.dart                  入口：初始化配置后注入 ProviderScope
  app.dart                   3 个 Tab（首页 / 收藏 / 我的）+ 更新提示观察者
  models/models.dart         数据模型
  providers/providers.dart   Riverpod 提供者 + 跨页刷新信号（vocabRevision / articleRevision）
  services/                  服务层：云端文章缓存 / 词典 / 翻译网关 / LLM / 词汇 / Edge TTS / 更新 / 配置…
  features/
    home/                    首页、来源筛选、文章卡片、继续阅读卡（搜索页已实现未接入）
    reading/                 阅读器（控制器 + 正文/顶栏/设置/选区/词卡）
    favorites/               收藏（单词 / 句子）、词汇 AI 整理
  screens/mine_screen.dart   「我的」：外观 / 数据管理 / 关于
  theme/                     设计 token（Go.*）与主题
  widgets/                   通用组件（GoCard / GoBtn / GoEmpty / GoPage…）、图标、底部导航
test/                        29 个测试文件（单元 + widget 测试）
integration_test/            真机集成测试（更新链路 / 阅读性能）
test_driver/                 性能测试驱动
tool/                        发布脚本（release.ps1）与生成脚本（globe / tailwind）
legacy/                      旧版 uni-app + Vue3 源码（v2.x，仅作历史留档）
assets/                      应用图标
docs/                        落地页（GitHub Pages，零构建）与更新/发布协议文档
```

---

## 开发

环境：Flutter `3.47.5`（stable）、Android SDK、JDK 17。

```bash
flutter pub get
flutter run                      # 连真机 / 模拟器运行
flutter test                     # 跑全部测试
flutter analyze                  # 静态分析
flutter build apk --release `
  --dart-define=ARTICLE_API_KEY=<文章接口密钥> `
  --dart-define=GATEWAY_KEY=<翻译网关密钥>   # 密钥必须在构建期注入
```

几点说明：

- 仅支持 `Android`，`applicationId` 为 `top.toneup.read`。
- 构建前需要 `android/key.properties`（`storePassword` / `keyPassword` / `keyAlias` / `storeFile`，keystore 用 `legacy/key.jks`）。该文件不入库，缺失时 Gradle 配置阶段直接失败（预期行为）；`debug` 与 `release` 复用同一套签名，可直接覆盖安装旧版且数据不丢。
- **密钥只在构建期注入，不写进源码**：手动 `flutter build apk` 要自己补上面两条 `--dart-define`；用 `tool\release.ps1` 发布时脚本会自动注入（优先环境变量 `ARTICLE_API_KEY` / `GATEWAY_KEY`，其次读不入库的 `tool\secrets.local.ps1`）。没注入的话装出来首页拉不到文章、点词也查不了。用户侧无需任何配置。
- 应用内无需填写任何服务地址或密钥——文章接口与翻译网关都已内置。
- 朗读默认直连 Edge TTS（无密钥、不过网关），失败回落系统 `TTS`：`Android 11+` 需要在 `AndroidManifest.xml` 的 `<queries>` 中声明 `android.intent.action.TTS_SERVICE`（仓库里已声明，升级 Flutter 插件后请留意别被覆盖）。
- 写界面时注意：**别给可能放大的文字套固定高度**，系统字号放大后会被裁切（回归用例：`test/home_article_list_test.dart`）。
- 常驻动画页面（骨架 / 转轮）的 widget 测试**不要用 `pumpAndSettle`**，用固定时长 `pump`。
- 发布：`powershell -ExecutionPolicy Bypass -File tool\release.ps1 -AppVersion X.Y.Z`，产物在 `dist/`。版本号唯一手改点是 `pubspec.yaml` 的 `version: X.Y.Z+BUILD`（`BUILD` 必须等于 `major*100 + minor*10 + patch`）。上传 GitHub Release 后需 **Publish**；客户端按 `releases/latest/download/` 固定链接更新，资产名 `ToneUP-read.apk` 与 `version.json` 不能改。详细步骤见 [上传安装包到 GitHub Release](docs/RELEASE_UPLOAD.md)，更新协议见 [UPDATE_PROTOCOL.md](docs/UPDATE_PROTOCOL.md)。

---

## TODO

1. 更新界面预览截图（`docs/screenshots/` 仍是旧版功能界面）
2. 文章搜索 / 筛选入口（搜索页与本地检索已实现，尚未接入首页；时间筛选未做）
3. 性能优化（超长文渲染、超大词汇表）
4. 离线词库：更准的词频、音标与释义来源

---

## 致谢

- 本项目基于开源项目 [GlobalOverview](https://github.com/None-Ptr/GlobalOverview)（作者 ShaDouBuShi123 & _Null_Ptr，MIT License）改装而来，原项目提供了英语时文阅读、AI 出题、错题本、单词本等核心设计与实现，在此对原作者致以诚挚的感谢。
- 特别感谢 ShaDouBuShi123 为原项目提供的图标和大力支持。
- 感谢 [43aquarius](https://github.com/43aquarius) 和 [HMUG12](https://github.com/HMUG12) 对原项目的贡献。
- 本项目作者：潼潼
