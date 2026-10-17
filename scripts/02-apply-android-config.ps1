# 第二/三阶段：生成标准 android 与 windows 平台目录
# 说明：Flutter 的 android/ 与 windows/ 目录由 flutter create 生成最稳妥，
#       本脚本生成的平台目录会自动保留我们写好的 Kotlin 源码与 AndroidManifest 配置。
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\02-apply-android-config.ps1

$ErrorActionPreference = 'Continue'
# 工程根目录 = 本脚本所在目录（scripts）的上一级，不写死盘符
$ProjRoot = Split-Path -Parent $PSScriptRoot

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "    !!  $text" -ForegroundColor Yellow }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Warn2 '未找到 flutter，请先运行 01-init-env.ps1 安装 Flutter SDK'
    exit 1
}

Push-Location $ProjRoot
try {
    Write-Step '备份自定义的 Android 源码与清单'
    $backup = Join-Path $env:TEMP ('tt_android_backup_' + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    if (Test-Path '.\android\app\src\main\kotlin') {
        Copy-Item '.\android\app\src\main\kotlin' (Join-Path $backup 'kotlin') -Recurse -Force
    }
    if (Test-Path '.\android\app\src\main\AndroidManifest.xml') {
        Copy-Item '.\android\app\src\main\AndroidManifest.xml' $backup -Force
    }
    Write-Ok "已备份到 $backup"

    Write-Step '生成平台目录（保留 lib 与 pubspec.yaml）'
    flutter create --platforms=android,windows --project-name timetable_app .

    Write-Step '恢复自定义的 Android 源码与清单'
    if (Test-Path (Join-Path $backup 'kotlin')) {
        $target = '.\android\app\src\main\kotlin'
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        Copy-Item (Join-Path $backup 'kotlin') $target -Recurse -Force
        Write-Ok 'Kotlin 源码已恢复'
    }
    if (Test-Path (Join-Path $backup 'AndroidManifest.xml')) {
        Copy-Item (Join-Path $backup 'AndroidManifest.xml') '.\android\app\src\main\AndroidManifest.xml' -Force
        Write-Ok 'AndroidManifest.xml 已恢复（含短信、精确闹钟、开机自启权限）'
    }

    Write-Step '校验 Android 包名是否为 com.example.timetable_app'
    $gradleFile = '.\android\app\build.gradle.kts'
    if (Test-Path $gradleFile) {
        Select-String -Path $gradleFile -Pattern 'namespace|applicationId' | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
    } else {
        Write-Warn2 '未找到 build.gradle.kts，请检查 Flutter 版本'
    }

    Write-Ok '平台目录处理完成'
} finally {
    Pop-Location
}
