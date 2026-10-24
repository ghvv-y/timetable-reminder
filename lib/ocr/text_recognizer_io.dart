// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 文字识别：移动端实现（ML Kit）
//
// 识别结果保留每行文字坐标（归一化到 0-1），
// 供 TableParser 划分「课程格」与「边侧时间栏」。
//
// 说明：APK 中打入的是 bundled 版 ML Kit 模型（com.google.mlkit:text-recognition），
// 模型随 APK 一起分发，完全离线识别，不依赖网络或 Google Play 服务。
// 默认识别器以拉丁脚本为主，数字与英文（如「08:00-08:45」）识别效果好，
// 中文课程名的识别质量取决于设备语言包，因此这里把原始文本一并返回，
// 便于界面展示与人工校对。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:image_picker/image_picker.dart';

import 'table_parser.dart';

/// 当前平台是否支持自动识别
bool get isOcrSupported => Platform.isAndroid || Platform.isIOS;

/// 图像预处理通道（放大 + 增强对比度）
const MethodChannel _imageChannel = MethodChannel('timetable_app/image');

/// 是否对小字课表做放大增强
///
/// 课表截图里每个课程格只有 ~80 像素宽，格子内的小字实际高度可能只有
/// 8~10 像素，识别引擎认不出来。放大后再识别能明显提升。
///
/// 默认关闭：实测清晰截图（竖屏全屏截图）本身就能认出来，
/// 过度放大反而会放大噪点。遇到字特别小、识别不全时再打开试。
bool ocrEnhanceSmallText = false;

/// 放大倍数（1 = 只增强对比度不放大）
int ocrUpscaleFactor = 2;

/// 识别结果：结构化文本块 + 原始文本（排错与人工校对用）
class OcrOutcome {
  /// 带坐标的文本行，交给 TableParser 解析
  final List<TextBlock> blocks;

  /// ML Kit 返回的原始文本
  final String rawText;

  const OcrOutcome({required this.blocks, required this.rawText});

  bool get isEmpty => blocks.isEmpty;

  int get lineCount => blocks.length;
}

/// 识别前先放大并增强图片；不支持或失败时用原图
Future<String> _prepareImage(String path) async {
  if (!Platform.isAndroid) return path;
  if (!ocrEnhanceSmallText) return path;
  try {
    final String? out = await _imageChannel.invokeMethod<String>(
      'prepare',
      <String, Object>{
        'path': path,
        'scale': ocrUpscaleFactor,
        'enhance': true,
      },
    );
    return (out == null || out.isEmpty) ? path : out;
  } catch (_) {
    return path; // 预处理失败不影响识别
  }
}

/// 识别图片中的文字
Future<OcrOutcome> recognizeBlocks(XFile file) async {
  if (!isOcrSupported) {
    return const OcrOutcome(blocks: <TextBlock>[], rawText: '');
  }

  // 小字课表：先放大 + 增强对比度，再交给识别引擎
  final String path = await _prepareImage(file.path);

  // 使用中文识别模型：课表以中文课程名为主，
  // 默认的拉丁模型认不出中文（APK 里只有 Latn_ctc 模型）。
  final mlkit.TextRecognizer recognizer = mlkit.TextRecognizer(
    script: mlkit.TextRecognitionScript.chinese,
  );
  try {
    final mlkit.InputImage image = mlkit.InputImage.fromFilePath(path);
    final mlkit.RecognizedText recognized =
        await recognizer.processImage(image);

    final String rawText = recognized.text;

    // 收集所有文本行，并据此推算图像的有效幅面
    final List<mlkit.TextLine> lines = <mlkit.TextLine>[];
    for (final mlkit.TextBlock block in recognized.blocks) {
      lines.addAll(block.lines);
    }
    if (lines.isEmpty) {
      return OcrOutcome(blocks: <TextBlock>[], rawText: rawText);
    }

    double width = 1;
    double height = 1;
    for (final mlkit.TextLine line in lines) {
      final Rect box = line.boundingBox;
      width = math.max(width, box.right);
      height = math.max(height, box.bottom);
    }

    final List<TextBlock> blocks = <TextBlock>[];
    for (final mlkit.TextLine line in lines) {
      final String text = line.text.trim();
      if (text.isEmpty) continue;
      final Rect box = line.boundingBox;
      blocks.add(TextBlock(
        text: text,
        left: box.left / width,
        top: box.top / height,
        right: box.right / width,
        bottom: box.bottom / height,
      ));
    }
    return OcrOutcome(blocks: blocks, rawText: rawText);
  } finally {
    await recognizer.close();
  }
}
