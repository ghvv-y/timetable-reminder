# 环境初始化脚本
# 作用：把开发工具与构建缓存全部指向 D 盘，并准备好工程目录
# 用法（在 PowerShell 中运行）：
#   powershell -ExecutionPolicy Bypass -File .\scripts\01-init-env.ps1
#
# 路径说明：本脚本不写死盘符，工程根目录由脚本自身位置推断，
# 因此工程无论放在 D:\ruanjian 还是别处都能直接使用。

$ErrorActionPreference = 'Continue'

# 工程根目录 = 本脚本所在目录（scripts）的上一级
$ProjRoot = Split-Path -Parent $PSScriptRoot

# 工具链目录：优先用环境变量，其次 D:\ruanjian\devtools，最后 $ProjRoot\devtools
$DevRoot = $env:DSH_DEVTOOLS
if (-not $DevRoot -or -not (Test-Path $DevRoot)) {
    if (Test-Path 'D:\ruanjian\devtools') {
        $DevRoot = 'D:\ruanjian\devtools'
    } else {
        $DevRoot = Join-Path (Split-Path -Parent $ProjRoot) 'devtools'
    }
}
$GradleHome = Join-Path $DevRoot 'gradle-home'
$PubCache   = Join-Path $DevRoot 'pub-cache'

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "    !!  $text" -ForegroundColor Yellow }

Write-Step '检查目标目录'
foreach ($d in @($DevRoot, $GradleHome, $PubCache)) {
    if (-not (Test-Path $d)) {
        try {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Write-Ok "已创建 $d"
        } catch {
            Write-Warn2 "无法创建 $d（可能没有写权限，请用管理员身份运行本脚本）"
        }
    } else {
        Write-Ok "已存在 $d"
    }
}

Write-Step '检查开发工具'
$tools = @{}
foreach ($c in @('flutter', 'dart', 'git', 'java')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) {
        $tools[$c] = $cmd.Source
        Write-Ok "$c -> $($cmd.Source)"
    } else {
        $tools[$c] = $null
        Write-Warn2 "$c 未安装"
    }
}

Write-Step '设置本次会话的环境变量（构建缓存全部落在 D 盘）'
$env:GRADLE_USER_HOME = $GradleHome
$env:PUB_CACHE = $PubCache
Write-Ok "GRADLE_USER_HOME = $env:GRADLE_USER_HOME"
Write-Ok "PUB_CACHE = $env:PUB_CACHE"

Write-Step '写入用户级环境变量（下次打开终端依然生效）'
try {
    [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME', $GradleHome, 'User')
    [Environment]::SetEnvironmentVariable('PUB_CACHE', $PubCache, 'User')
    Write-Ok 'GRADLE_USER_HOME / PUB_CACHE 已写入用户环境变量'
} catch {
    Write-Warn2 "写入用户环境变量失败：$($_.Exception.Message)"
}

if (-not $tools['flutter']) {
    Write-Step 'Flutter 未安装，给出安装指引'
    Write-Host '    请按以下步骤安装（全部装到 D 盘）：' -ForegroundColor Gray
    Write-Host '' 
    Write-Host '    1. 下载 Flutter SDK（Windows 压缩包）' -ForegroundColor Gray
    Write-Host '       https://docs.flutter.dev/get-started/install/windows' -ForegroundColor Gray
    Write-Host ''
    Write-Host "    2. 解压到：$(Join-Path $DevRoot 'flutter')" -ForegroundColor Gray
    Write-Host "       并把 $(Join-Path $DevRoot 'flutter\bin') 加入 PATH" -ForegroundColor Gray
    Write-Host ''
    Write-Host "    3. 安装 JDK 17 到：$(Join-Path $DevRoot 'jdk17')" -ForegroundColor Gray
    Write-Host "       设置 JAVA_HOME=$(Join-Path $DevRoot 'jdk17')" -ForegroundColor Gray
    Write-Host ''
    Write-Host "    4. 安装 Android SDK，路径设为：$(Join-Path $DevRoot 'android-sdk')" -ForegroundColor Gray
    Write-Host "       设置 ANDROID_SDK_ROOT=$(Join-Path $DevRoot 'android-sdk')" -ForegroundColor Gray
    Write-Host ''
    Write-Host '    5. 运行：flutter doctor --android-licenses' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    完成后重新运行本脚本即可。' -ForegroundColor Gray
    exit 0
}

Write-Step 'Flutter 版本'
flutter --version

Write-Step '拉取工程依赖'
Push-Location $ProjRoot
try {
    flutter pub get
    Write-Ok 'flutter pub get 完成'
} catch {
    Write-Warn2 "flutter pub get 失败：$($_.Exception.Message)"
} finally {
    Pop-Location
}

Write-Step '环境初始化完成'
Write-Host "工程目录：$ProjRoot" -ForegroundColor Gray
Write-Host "工具目录：$DevRoot" -ForegroundColor Gray
Write-Host "下一步：scripts\02-apply-android-config.ps1（如 android 目录缺失）" -ForegroundColor Gray
Write-Host "然后：scripts\03-build-apk.ps1 或 scripts\04-build-windows.ps1" -ForegroundColor Gray
