// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 文字识别：桌面端实现（不支持自动识别）
//
// 返回空结果，界面会提示用户改为手动补充作息时间与课程。

import 'package:image_picker/image_picker.dart';

import 'table_parser.dart';

bool get isOcrSupported => false;

/// 小字放大增强开关（桌面端无实现，仅为接口一致）
bool ocrEnhanceSmallText = true;

/// 放大倍数（桌面端无实现，仅为接口一致）
int ocrUpscaleFactor = 2;

/// 识别结果：结构化文本块 + 原始文本
class OcrOutcome {
  final List<TextBlock> blocks;
  final String rawText;

  const OcrOutcome({required this.blocks, required this.rawText});

  bool get isEmpty => blocks.isEmpty;

  int get lineCount => blocks.length;
}

Future<OcrOutcome> recognizeBlocks(XFile file) async =>
    const OcrOutcome(blocks: <TextBlock>[], rawText: '');
