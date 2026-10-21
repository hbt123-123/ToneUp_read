﻿﻿﻿﻿﻿# 生成发布物并打印「上传清单」。上传动作由人工在 GitHub Release 页面完成。
#
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -AppVersion 3.5.0
#
# 注意两个 Windows 上的坑（都已经踩过）：
#   1. 本文件必须存成 **UTF-8 with BOM**：PowerShell 5.1 会按 GBK 解释无 BOM 的 .ps1，
#      中文注释会被拆成语法错误。
#   2. 参数不能叫 `-Version`：它会被 powershell.exe 自己的同名开关抢走。
#
# 密钥：文章接口 / 翻译网关的密钥由本脚本用 --dart-define 编译进 APK（见「2. 密钥注入」）。
#       密钥本身不入库，来源是环境变量或 tool\secrets.local.ps1（已 gitignore）。
#
# 产出（都在 dist\，dist 已被 .gitignore 忽略）：
#   version.json        —— 客户端检查更新读的就是它（资产名必须固定）
#   ToneUP-read.apk  —— 资产名必须固定，客户端拼出来的下载地址才不会变
#
# 设计约束：客户端不走 api.github.com，只靠 `releases/latest/download/<固定资产名>`
# 这个免 API 固定链接，所以两个资产名一个字都不能改，且 Release 必须 Publish（草稿/预发布都不算）。
param(
    [Parameter(Mandatory = $true)][string]$AppVersion,       # 形如 3.5.0
    [string]$NotesFile = 'release-notes.md',
    [switch]$Tag                                            # 顺带在本地打 tag v<Version>
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

# —— 1. 版本一致性：pubspec 是唯一手改点，其余全部由它推导 ——
$pubspec = Get-Content pubspec.yaml -Raw -Encoding UTF8
$m = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$')
if (-not $m.Success) { throw 'pubspec.yaml 里没找到形如 version: 3.5.0+350 的版本号' }
$major = [int]$m.Groups[1].Value; $minor = [int]$m.Groups[2].Value; $patch = [int]$m.Groups[3].Value
$pubCode = [int]$m.Groups[4].Value
$pubVer = "$major.$minor.$patch"
if ($pubVer -ne $AppVersion.TrimStart('v')) {
    throw "pubspec.yaml 是 $pubVer，跟传入的 $AppVersion 不一致——先在 pubspec.yaml 里改版本号，再跑这个脚本。"
}
$expectCode = $major * 100 + $minor * 10 + $patch
if ($pubCode -ne $expectCode) {
    throw "pubspec 的 build number 应为 $expectCode（major*100+minor*10+patch），当前是 $pubCode。"
}
# 变量名别叫 $tag！PowerShell 大小写不敏感，会和 [switch]$Tag 撞成同一个变量。
$tagName = "v$pubVer"

# —— 2. 密钥注入（不入库：低于源码与仓库）——
# 客户端的内置密钥在编译期用 --dart-define 塞进去，源码里只有空默认值。
# 取值优先级：环境变量 > tool\secrets.local.ps1（已 gitignore，两行 ASCII 赋值即可）。
$secretsFile = Join-Path $PSScriptRoot 'secrets.local.ps1'
if (Test-Path $secretsFile) { . $secretsFile }   # 定义 $ARTICLE_API_KEY / $GATEWAY_KEY
$articleKey = if ($env:ARTICLE_API_KEY) { $env:ARTICLE_API_KEY } else { $ARTICLE_API_KEY }
$gatewayKey = if ($env:GATEWAY_KEY) { $env:GATEWAY_KEY } else { $GATEWAY_KEY }
if ([string]::IsNullOrWhiteSpace($articleKey) -or [string]::IsNullOrWhiteSpace($gatewayKey)) {
    throw @'
缺少 ARTICLE_API_KEY / GATEWAY_KEY。二选一：
  1) 构建前设置同名环境变量；
  2) 新建 tool\secrets.local.ps1（不入库），内容两行：
       $ARTICLE_API_KEY = '文章接口密钥'
       $GATEWAY_KEY     = '翻译网关密钥'
不做注入的话，装出来的 App 没有密钥，首页拉不到文章、点词也查不了。
'@
}

# —— 3. 构建 ——
Write-Host "构建 release APK（$pubVer / versionCode $pubCode）…" -ForegroundColor Cyan
flutter build apk --release `
    --dart-define=ARTICLE_API_KEY=$articleKey `
    --dart-define=GATEWAY_KEY=$gatewayKey
$apkPath = 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path $apkPath)) { throw "找不到构建产物 $apkPath" }

# —— 4. 校验和与大小（手抄必错，所以由脚本算）——
$sha256 = (Get-FileHash $apkPath -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $apkPath).Length

# —— 5. 更新说明：release-notes.md 是唯一来源，同时进 version.json 和 Release 正文 ——
$notes = ''
if (Test-Path $NotesFile) { $notes = (Get-Content $NotesFile -Raw -Encoding UTF8).Trim() }
if ([string]::IsNullOrWhiteSpace($notes)) {
    Write-Warning "$NotesFile 为空或不存在，卡片里将没有更新说明。"
}

# —— 6. 生成产物 ——
$dist = Join-Path (Get-Location) 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$url = 'https://github.com/hbt123-123/ToneUp_read/releases/latest/download/ToneUP-read.apk'
$obj = [ordered]@{
    version     = $pubVer
    versionCode = $pubCode
    url         = $url
    sha256      = $sha256
    size        = $size
    notes       = $notes
}
# ConvertTo-Json 会把中文转成 \uXXXX，JSON 转义合法，客户端按 utf8 解码即可
$jsonText = $obj | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $dist 'version.json'), $jsonText, (New-Object Text.UTF8Encoding($false)))
Copy-Item $apkPath (Join-Path $dist 'ToneUP-read.apk') -Force

if ($Tag) {
    git tag $tagName
    Write-Host "已在本地打 tag $tagName（推送请自行执行：git push origin $tagName）" -ForegroundColor Yellow
}

# —— 7. 上传清单 ——
Write-Host ''
Write-Host '================ 上传清单（GitHub → Releases → Draft a new release）================' -ForegroundColor Green
Write-Host "Tag:        $tagName            （不存在就现场新建；必须是 Publish，草稿/预发布不算）"
Write-Host "标题:        $tagName"
Write-Host "正文:        粘贴 $NotesFile 的内容"
Write-Host "资产 1:      dist\ToneUP-read.apk     ← 名字必须是 ToneUP-read.apk"
Write-Host "资产 2:      dist\version.json            ← 名字必须是 version.json"
Write-Host ''
Write-Host "versionCode : $pubCode"
Write-Host "sha256      : $sha256"
Write-Host "size        : $size 字节（$([math]::Round($size/1MB,1)) MB）"
Write-Host ''
Write-Host '发布后自检（不改代码就能验证凭据是否正确）：' -ForegroundColor Green
Write-Host "  curl -L $url -o nul -w `"%{http_code}`""
Write-Host '    → 200 且不是 GitHub 的 404 页面，说明资产名对上了。'
Write-Host '==============================================================================' -ForegroundColor Green
