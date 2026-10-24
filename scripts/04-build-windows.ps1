# 课表提醒 (Timetable Reminder)
# Copyright (C) 2026 课表提醒 contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
# （或你选择的更高版本）的条款重新分发和/或修改它。
# 协议全文见项目根目录的 LICENSE 文件。
#
# 打包 Windows 电脑版
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\04-build-windows.ps1

$ErrorActionPreference = 'Continue'
# 路径由脚本自身位置推断，不写死盘符
$ProjRoot = Split-Path -Parent $PSScriptRoot
$DevRoot = $env:DSH_DEVTOOLS
if (-not $DevRoot -or -not (Test-Path $DevRoot)) {
    if (Test-Path 'D:\ruanjian\devtools') {
        $DevRoot = 'D:\ruanjian\devtools'
    } else {
        $DevRoot = Join-Path (Split-Path -Parent $ProjRoot) 'devtools'
    }
}
$OutDir = Join-Path $ProjRoot 'build\windows-out'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host '未找到 flutter，请先运行 scripts\01-init-env.ps1' -ForegroundColor Yellow
    exit 1
}

$env:GRADLE_USER_HOME = Join-Path $DevRoot 'gradle-home'
$env:PUB_CACHE = Join-Path $DevRoot 'pub-cache'

Push-Location $ProjRoot
try {
    Write-Host '==> 拉取依赖' -ForegroundColor Cyan
    flutter pub get

    Write-Host '==> 构建 Windows 版本' -ForegroundColor Cyan
    flutter build windows --release

    $src = Join-Path $ProjRoot 'build\windows\x64\runner\Release'
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        Copy-Item (Join-Path $src '*') $OutDir -Recurse -Force
        Write-Host "    程序目录：$OutDir" -ForegroundColor Green
        Write-Host "    可执行文件：$(Join-Path $OutDir 'timetable_app.exe')" -ForegroundColor Green
    } else {
        Write-Host '    未找到构建产物，请检查上方日志' -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}

Write-Host '注意：电脑端不发送短信（无短信通道），只用于管理课表、编辑闹钟与导出备份。' -ForegroundColor Gray
