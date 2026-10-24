// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 文字识别入口：按平台切换实现
// - 移动端（Android / iOS）：使用 ML Kit 进行文字识别
// - 桌面端（Windows / macOS / Linux）：不支持识别，返回空结果

export 'text_recognizer_desktop.dart'
    if (dart.library.io) 'text_recognizer_io.dart';
