# 课表提醒 (Timetable Reminder)
# Copyright (C) 2026 课表提醒 contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
# （或你选择的更高版本）的条款重新分发和/或修改它。
# 协议全文见项目根目录的 LICENSE 文件。
#
# 打包安卓 APK（安装到手机）
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\03-build-apk.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\03-build-apk.ps1 -SplitPerAbi

param(
    [switch]$SplitPerAbi
)

$ErrorActionPreference = 'Continue'
# 路径由脚本自身位置推断，不写死盘符：工程根 = scripts 的上一级
$ProjRoot = Split-Path -Parent $PSScriptRoot
$DevRoot = $env:DSH_DEVTOOLS
if (-not $DevRoot -or -not (Test-Path $DevRoot)) {
    if (Test-Path 'D:\ruanjian\devtools') {
        $DevRoot = 'D:\ruanjian\devtools'
    } else {
        $DevRoot = Join-Path (Split-Path -Parent $ProjRoot) 'devtools'
    }
}
$OutDir = Join-Path $ProjRoot 'dist'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host '未找到 flutter，请先运行 scripts\01-init-env.ps1' -ForegroundColor Yellow
    exit 1
}

$env:GRADLE_USER_HOME = Join-Path $DevRoot 'gradle-home'
$env:PUB_CACHE = Join-Path $DevRoot 'pub-cache'

Push-Location $ProjRoot
try {
    Write-Host '==> 清理旧构建' -ForegroundColor Cyan
    flutter clean

    Write-Host '==> 拉取依赖' -ForegroundColor Cyan
    flutter pub get

    Write-Host '==> 开始打包（首次会下载 Gradle 与依赖，请耐心等待）' -ForegroundColor Cyan
    if ($SplitPerAbi) {
        flutter build apk --release --split-per-abi
    } else {
        flutter build apk --release
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $apks = Get-ChildItem -Path (Join-Path $ProjRoot 'build\app\outputs\flutter-apk') -Filter '*.apk' -ErrorAction SilentlyContinue
    if ($apks) {
        foreach ($apk in $apks) {
            Copy-Item $apk.FullName $OutDir -Force
            Write-Host "    APK：$(Join-Path $OutDir $apk.Name)" -ForegroundColor Green
        }
    } else {
        Write-Host '    未找到 APK，请检查上方构建日志' -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}

Write-Host '把 APK 传到手机安装，安装后请依次授予：短信权限、精确闹钟权限、通知（用于手表同步）。' -ForegroundColor Gray
