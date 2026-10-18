// 离线 PP-OCR 识别服务（Dart 侧封装）
//
// 调用链：
//   Dart  ->  原生 timetable_app/ocr "recognize"
//          ->  Kotlin: Bitmap 解码 + 网格切分 + 逐格 PP-OCR
//          返回 JSON: { cells: [{row, col, lines: [...]}], grid: {ys, xs} }
//   Dart  <-  cell_parser.parseSchedule() 解析成课程 + 作息时间
//
// 和旧的 ML Kit 流程的区别：
//   旧：整图 OCR（相邻格子文字会串行，中文课名容易乱）
//   新：逐格 OCR（桌面端验证过的方式，时间栏 12/12 精确）

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'cell_parser.dart';

/// 识别失败（带可读原因，便于界面直接展示）
class PpfOcrException implements Exception {
  final String message;
  PpfOcrException(this.message);

  @override
  String toString() => message;
}

class PpfOcrService {
  static const MethodChannel _channel = MethodChannel('timetable_app/ocr');

  /// 当前平台是否支持（只有安卓打包了模型）
  static bool get isSupported => Platform.isAndroid;

  /// 识别一张图片，返回课程 + 作息时间
  ///
  /// [imagePath] 本地图片路径。耗时操作（大图约 3~10 秒），
  /// 调用方应在 UI 上显示进度。
  static Future<CellParseResult> recognize(String imagePath) async {
    if (!isSupported) {
      throw PpfOcrException('离线识别目前只支持安卓');
    }
    if (!File(imagePath).existsSync()) {
      throw PpfOcrException('找不到图片文件');
    }

    String? raw;
    try {
      raw = await _channel.invokeMethod<String>(
        'recognize',
        <String, Object>{'imagePath': imagePath},
      );
    } on PlatformException catch (e) {
      throw PpfOcrException(e.message ?? '识别失败');
    } on MissingPluginException {
      throw PpfOcrException('当前安装包还不支持离线识别，请更新 App');
    }

    if (raw == null || raw.isEmpty) {
      throw PpfOcrException('识别没有返回结果');
    }

    final Map<String, Object?> data =
        Map<String, Object?>.from(jsonDecode(raw) as Map);
    final List<Object?> rawCells =
        (data['cells'] as List<Object?>?) ?? <Object?>[];

    final List<OcrCell> cells = <OcrCell>[];
    for (final Object? item in rawCells) {
      if (item is! Map) continue;
      final Map<String, Object?> m = Map<String, Object?>.from(item);
      final int row = (m['row'] as num?)?.toInt() ?? 0;
      final int col = (m['col'] as num?)?.toInt() ?? 0;
      final List<String> lines = ((m['lines'] as List<Object?>?) ?? <Object?>[])
          .map((Object? e) => e.toString())
          .where((String s) => s.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      cells.add(OcrCell(row: row, col: col, lines: lines));
    }

    if (cells.isEmpty) {
      throw PpfOcrException('这张图里没识别出任何文字');
    }

    final CellParseResult parsed = parseSchedule(cells);
    if (parsed.courses.isEmpty && parsed.periods.isEmpty) {
      throw PpfOcrException(
          parsed.warnings.isEmpty ? '没解析出课表内容' : parsed.warnings.first);
    }
    return parsed;
  }

  /// 直接返回原始格子文字（排查用，界面上可以展开看）
  static Future<List<OcrCell>> recognizeCells(String imagePath) async {
    if (!isSupported) throw PpfOcrException('离线识别目前只支持安卓');
    final String? raw = await _channel.invokeMethod<String>(
      'recognize',
      <String, Object>{'imagePath': imagePath},
    );
    if (raw == null || raw.isEmpty) return <OcrCell>[];
    final Map<String, Object?> data =
        Map<String, Object?>.from(jsonDecode(raw) as Map);
    final List<Object?> list = (data['cells'] as List<Object?>?) ?? <Object?>[];
    final List<OcrCell> out = <OcrCell>[];
    for (final Object? item in list) {
      if (item is! Map) continue;
      final Map<String, Object?> m = Map<String, Object?>.from(item);
      out.add(OcrCell(
        row: (m['row'] as num?)?.toInt() ?? 0,
        col: (m['col'] as num?)?.toInt() ?? 0,
        lines: ((m['lines'] as List<Object?>?) ?? <Object?>[])
            .map((Object? e) => e.toString())
            .toList(),
      ));
    }
    out.sort((OcrCell a, OcrCell b) =>
        a.row != b.row ? a.row - b.row : a.col - b.col);
    return out;
  }
}
