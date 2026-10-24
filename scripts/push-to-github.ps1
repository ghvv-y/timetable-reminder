# 课表提醒 (Timetable Reminder)
# Copyright (C) 2026 课表提醒 contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
# （或你选择的更高版本）的条款重新分发和/或修改它。
# 协议全文见项目根目录的 LICENSE 文件。
#
# 推送到 GitHub
#
# 前置条件（只需做一次）：
#   1. 把公钥加到 GitHub：https://github.com/settings/keys
#      公钥内容在 C:\Users\<你>\.ssh\id_ed25519_github.pub
#   2. 在 GitHub 上建一个空仓库（不要勾 Add a README）
#
# 然后运行：
#   powershell -ExecutionPolicy Bypass -File .\scripts\push-to-github.ps1
#
# 脚本只做三件事：设 remote、验证 SSH、推送。不会改你的代码。

$ErrorActionPreference = 'Stop'
$ProjRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjRoot

function Step($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "    !!  $t" -ForegroundColor Yellow }

# ---------- 1. 收集仓库信息 ----------
Step '填写仓库信息'

$existing = git remote get-url origin 2>$null
if ($existing) {
    $url = $existing
    Ok "已有 remote：$url"
} else {
    Write-Host '    GitHub 用户名（不是邮箱，是 github.com/<这里> 那一段）：'
    $user = Read-Host '    用户名'
    if (-not $user) { Warn '用户名不能为空'; exit 1 }

    Write-Host '    仓库名（没有的话先在 GitHub 上建一个空仓库）：'
    $repo = Read-Host '    仓库名 [timetable-reminder]'
    if (-not $repo) { $repo = 'timetable-reminder' }

    $url = "git@github.com:$user/$repo.git"
    git remote add origin $url
    Ok "remote = $url"
}

# ---------- 2. 验证 SSH ----------
Step '验证 SSH 认证'
$test = (& ssh -o ConnectTimeout=15 -T git@github.com 2>&1) -join ' '
if ($test -match 'successfully authenticated') {
    Ok 'SSH 认证通过'
} elseif ($test -match 'Permission denied \(publickey\)') {
    Warn 'SSH 公钥还没加到 GitHub'
    Write-Host ''
    Write-Host '  请把下面这个公钥粘贴到 https://github.com/settings/keys' -ForegroundColor Yellow
    Write-Host '  （点 New SSH key，Title 随便填，Key 粘贴下面这一整行）' -ForegroundColor Yellow
    Write-Host ''
    $pub = Join-Path $env:USERPROFILE '.ssh\id_ed25519_github.pub'
    if (Test-Path $pub) {
        Get-Content $pub | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    } else {
        Warn "找不到公钥文件：$pub"
    }
    Write-Host ''
    Write-Host '  加完后再跑一次这个脚本。' -ForegroundColor Yellow
    exit 1
} else {
    Warn "SSH 连接异常：$test"
    exit 1
}

# ---------- 3. 推送 ----------
Step '推送到 GitHub'
git branch -M main
Write-Host "    正在推送 main -> $url"

$env:GIT_TERMINAL_PROMPT = '0'
$push = (& git push -u origin main 2>&1) -join "`n"
Write-Host $push

if ($LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Green
    Write-Host ' 推送成功' -ForegroundColor Green
    Write-Host '====================================================' -ForegroundColor Green
    $web = $url -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
    Write-Host "  $web" -ForegroundColor White
} else {
    Warn '推送失败，把上面的报错发给开发者'
    exit 1
}
