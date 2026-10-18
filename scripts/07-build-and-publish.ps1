# 一键打包并把安装包路径打印出来
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\07-build-and-publish.ps1
#
# 做四件事：
#   1. 校正 Flutter 的引擎版本标记（修复过 git 仓库后必需，否则会误重下 Dart SDK）
#   2. 读 pubspec.yaml 的版本号，作为安装包文件名（如 课表提醒-0.2.3.apk）
#   3. 打包 release APK
#   4. 打印安装包的完整路径（复制这段路径即可发人）

$ErrorActionPreference = 'Continue'

$ProjRoot = Split-Path -Parent $PSScriptRoot
$DevRoot = $env:DSH_DEVTOOLS
if (-not $DevRoot -or -not (Test-Path $DevRoot)) {
    if (Test-Path 'D:\ruanjian\devtools') {
        $DevRoot = 'D:\ruanjian\devtools'
    } else {
        $DevRoot = Join-Path (Split-Path -Parent $ProjRoot) 'devtools'
    }
}

function Step($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    !!  $t" -ForegroundColor Yellow }

$EngineVersion = '692136cb6582dbfc5af3fb33c2515a069f2f66d0'
$FlutterRoot = Join-Path $DevRoot 'flutter'
$CacheDir = Join-Path $FlutterRoot 'bin\cache'

Step '校正 Flutter 引擎版本标记'
$env:FLUTTER_PREBUILT_ENGINE_VERSION = $EngineVersion
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'

$currentSdk = Join-Path $CacheDir 'dart-sdk'
$currentOk = Test-Path (Join-Path $currentSdk 'bin\dart.exe')

if (-not $currentOk) {
    $goodSdk = Get-ChildItem $CacheDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like 'dart-sdk*' -and
            (Test-Path (Join-Path $_.FullName 'bin\dart.exe'))
        } | Select-Object -First 1
    if ($goodSdk) {
        Warn "dart-sdk 不完整，从 $($goodSdk.Name) 恢复"
        if (Test-Path $currentSdk) {
            Remove-Item $currentSdk -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($goodSdk.Name -ne 'dart-sdk') {
            Rename-Item $goodSdk.FullName $currentSdk -Force
        }
        $currentOk = Test-Path (Join-Path $currentSdk 'bin\dart.exe')
    }
}
if ($currentOk) { Ok 'dart-sdk 就绪' } else { Warn 'Dart SDK 缺失，需先恢复' }

Get-ChildItem $CacheDir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'dart-sdk.old*' } |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

foreach ($stamp in @('engine.stamp', 'engine-dart-sdk.stamp')) {
    [System.IO.File]::WriteAllText((Join-Path $CacheDir $stamp), $EngineVersion)
}
Ok 'engine.stamp / engine-dart-sdk.stamp 已校正'

$env:JAVA_HOME        = Join-Path $DevRoot 'jdk17'
$env:ANDROID_SDK_ROOT = Join-Path $DevRoot 'android-sdk'
$env:ANDROID_HOME     = Join-Path $DevRoot 'android-sdk'
$env:GRADLE_USER_HOME = Join-Path $DevRoot 'gradle-home'
$env:PUB_CACHE        = Join-Path $DevRoot 'pub-cache'
$env:PATH = (@(
        (Join-Path $DevRoot 'flutter\bin'),
        (Join-Path $DevRoot 'git\cmd'),
        (Join-Path $DevRoot 'jdk17\bin')
    ) + ($env:PATH -split ';')) -join ';'

$flutter = Join-Path $DevRoot 'flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) {
    Warn "找不到 Flutter：$flutter"
    exit 1
}

Step '读取版本号'
$pubspec = Join-Path $ProjRoot 'pubspec.yaml'
$version = 'unknown'
foreach ($line in Get-Content $pubspec) {
    if ($line -match '^version:\s*(\S+)') {
        $version = $Matches[1].Split('+')[0]
        break
    }
}
Ok "版本 $version"

Step '打包 release APK'
# 说明：清过 .dart_tool 后，第一次构建会因重建插件链接而报
# 「symlink support / Developer Mode」，第二次即通过。这里自动重试一次，
# 省得用户手动再跑一遍。
$attempt = 0
$maxAttempts = 3
$code = 1
while ($attempt -lt $maxAttempts) {
    $attempt++
    if ($attempt -gt 1) {
        Warn "第 $attempt 次尝试（首次常因重建插件链接而失败，属正常）"
        foreach ($stamp in @('engine.stamp', 'engine-dart-sdk.stamp')) {
            [System.IO.File]::WriteAllText((Join-Path $CacheDir $stamp), $EngineVersion)
        }
    }
    Push-Location $ProjRoot
    try {
        & $flutter build apk --release --target-platform android-arm,android-arm64
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -eq 0) { break }
}

if ($code -ne 0) {
    Warn "打包失败（试了 $attempt 次），退出码 $code"
    exit 1
}

$built = Join-Path $ProjRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $built)) {
    Warn "找不到构建产物：$built"
    exit 1
}

Step '复制到 dist'
$dist = Join-Path $ProjRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Get-ChildItem $dist -Filter '*.apk' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "    清理旧包 $($_.Name)" -ForegroundColor Gray
    Remove-Item $_.FullName -Force
}

$outName = "课表提醒-$version.apk"
$outPath = Join-Path $dist $outName
Copy-Item $built $outPath -Force

$sizeMB = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
Ok "$outName  ($sizeMB MB)"

Write-Host ''
Write-Host '====================================================' -ForegroundColor Green
Write-Host ' 安装包已生成' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Green
Write-Host ''
Write-Host "  $outPath" -ForegroundColor White
Write-Host ''
Write-Host "  版本：$version    大小：$sizeMB MB" -ForegroundColor Gray
Write-Host '  把这个路径复制发人即可' -ForegroundColor Gray
Write-Host ''