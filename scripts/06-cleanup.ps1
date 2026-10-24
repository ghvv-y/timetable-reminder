# 课表提醒 (Timetable Reminder)
# Copyright (C) 2026 课表提醒 contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
# （或你选择的更高版本）的条款重新分发和/或修改它。
# 协议全文见项目根目录的 LICENSE 文件。
#
# 清理磁盘占用（只删可再生的文件，绝不碰工具链本体）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\scripts\06-cleanup.ps1
#
# 【重要】早期版本提供过 -Aggressive 模式，会删除 Flutter 的 .git 与缓存，
# 导致工具链损坏（Flutter 启动时报 "not a clone of the GitHub project"）。
# 该模式已永久移除。
#
# 本脚本只删：
#   1. 构建中间产物（build、.dart_tool）—— 下次打包自动重建
#   2. 重复的 APK 副本 —— 只保留一个可安装的
#   3. Gradle 依赖缓存 —— 下次打包重新下载（可选，需显式加 -CleanGradleCache）
#
# 绝对不会删：Flutter SDK 及其 .git、Android SDK、JDK、pub-cache、源码、安装包

param(
    [switch]$CleanGradleCache
)

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

# 安全护栏：这些路径一律不许删
$FORBIDDEN = @(
    (Join-Path $DevRoot 'flutter'),
    (Join-Path $DevRoot 'flutter\.git'),
    (Join-Path $DevRoot 'flutter\bin'),
    (Join-Path $DevRoot 'android-sdk'),
    (Join-Path $DevRoot 'jdk17'),
    (Join-Path $DevRoot 'pub-cache'),
    (Join-Path $DevRoot 'git')
)

function Size-MB($p) {
    if (-not (Test-Path $p)) { return 0 }
    [math]::Round((Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB, 1)
}
function Step($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    !!  $t" -ForegroundColor Yellow }

function Remove-Safe($path) {
    foreach ($f in $FORBIDDEN) {
        if ($path.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)) {
            Warn "拒绝删除受保护路径：$path"
            return $false
        }
    }
    if (-not (Test-Path $path)) { return $false }
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    return -not (Test-Path $path)
}

$freed = 0

Write-Host '====================================================' -ForegroundColor White
Write-Host ' 清理可再生的文件' -ForegroundColor White
Write-Host '====================================================' -ForegroundColor White
Write-Host "工程：$ProjRoot"
Write-Host "工具：$DevRoot"
Write-Host ''

Step '停止占用文件的进程'
$gradleBat = Get-ChildItem (Join-Path $DevRoot 'gradle-home\wrapper\dists') `
    -Recurse -Filter 'gradle.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gradleBat) {
    $env:JAVA_HOME = Join-Path $DevRoot 'jdk17'
    & $gradleBat.FullName --stop 2>&1 | Out-Null
}
Start-Sleep -Seconds 2
Get-Process java, dart -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Ok '已清理占用进程'

Step '删除构建中间产物（下次打包自动重建）'
foreach ($name in @('build', '.dart_tool')) {
    $p = Join-Path $ProjRoot $name
    if (Test-Path $p) {
        $before = Size-MB $p
        if (Remove-Safe $p) { $freed += $before; Ok "$name 释放 $before MB" }
        else { Warn "未能全部删除 $name（剩余 $(Size-MB $p) MB）" }
    } else { Warn "$name 不存在，跳过" }
}

Step '删除重复的 APK 副本'
$dist = Join-Path $ProjRoot 'dist'
foreach ($name in @('app-release.apk', 'app-debug.apk')) {
    $f = Join-Path $dist $name
    if (Test-Path $f) {
        $before = [math]::Round((Get-Item $f).Length / 1MB, 1)
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        $freed += $before
        Ok "删除 $name，释放 $before MB"
    }
}
$keep = Get-ChildItem $dist -Filter '*.apk' -ErrorAction SilentlyContinue
if ($keep) { Ok ('保留安装包：' + (($keep | ForEach-Object { $_.Name }) -join '、')) }

if ($CleanGradleCache) {
    Step '删除 Gradle 依赖缓存（下次打包需重新下载，约 10 分钟）'
    $gc = Join-Path $DevRoot 'gradle-home\caches'
    if (Test-Path $gc) {
        $before = Size-MB $gc
        if (Remove-Safe $gc) { $freed += $before; Ok "释放 $before MB" }
        else { Warn "剩余 $(Size-MB $gc) MB" }
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor White
Write-Host (" 本次共释放约 {0} MB" -f [math]::Round($freed, 1)) -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor White
Write-Host ''

Step '当前占用明细'
$sum = 0
foreach ($p in @(
        (Join-Path $DevRoot 'flutter'),
        (Join-Path $DevRoot 'android-sdk'),
        (Join-Path $DevRoot 'gradle-home'),
        (Join-Path $DevRoot 'jdk17'),
        (Join-Path $DevRoot 'pub-cache'),
        $ProjRoot
    )) {
    $s = Size-MB $p
    $sum += $s
    "  {0,9} MB  {1}" -f $s, $p
}
"  ---------"
"  {0,9} MB  合计" -f $sum

Write-Host ''
Write-Host '想再省空间可以手动删 gradle-home\caches（下次打包重新下载）' -ForegroundColor Gray
Write-Host '但请勿删除 flutter 目录下的任何内容，包括 .git' -ForegroundColor Yellow