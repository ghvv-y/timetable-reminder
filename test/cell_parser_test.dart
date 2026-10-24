// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 格子 -> 课程 / 作息时间 的解析测试
//
// 样例数据来自真实课表图片经 Kotlin PP-OCR 引擎识别后得到的格子文字，
// 所以这组测试同时也验证了「识别 + 解析」这条链路的产物形态。

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/ocr/cell_parser.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/model/period_time.dart';

/// 造一组贴近真实的格子
List<OcrCell> sampleCells() {
  final List<OcrCell> cells = <OcrCell>[
    // 时间栏（12 节）
    const OcrCell(row: 0, col: 0, lines: <String>['第(08:00-08:45)']),
    const OcrCell(row: 1, col: 0, lines: <String>['第(08:50-09:35)']),
    const OcrCell(row: 2, col: 0, lines: <String>['第(10:05-10:50)']),
    const OcrCell(row: 3, col: 0, lines: <String>['第(10:55-11:40)']),
    const OcrCell(row: 4, col: 0, lines: <String>['第(13:30-14:15)']),
    const OcrCell(row: 5, col: 0, lines: <String>['第(14:20-15:05)']),
    const OcrCell(row: 6, col: 0, lines: <String>['第(15:35-16:20)']),
    const OcrCell(row: 7, col: 0, lines: <String>['第(16:25-17:10)']),
    const OcrCell(row: 8, col: 0, lines: <String>['第(18:00-18:45)']),
    const OcrCell(row: 9, col: 0, lines: <String>['第(18:50-19:35)']),
    const OcrCell(row: 10, col: 0, lines: <String>['第(19:40-20:25)']),
    const OcrCell(row: 11, col: 0, lines: <String>['第(20:30-21:15)']),

    // 周一 1-2 节（跨两个格子行：课名在上，教室在下）
    const OcrCell(row: 0, col: 1, lines: <String>[
      '大学英语（1）_33', '黄怡凡*', '7-8周', '1-2节'
    ]),
    const OcrCell(row: 1, col: 1, lines: <String>['校本部冷链大楼冷链-A202']),

    // 周二 1-2 节（单格全字段）
    const OcrCell(row: 0, col: 2, lines: <String>[
      '高等数学A(1)_04', '张怡通*', '3-16周', '1-2节'
    ]),
    const OcrCell(row: 1, col: 2, lines: <String>['校本部3号教学楼3-310']),

    // 周四 3-4 节
    const OcrCell(row: 2, col: 4, lines: <String>[
      '人工智能与信息技术基础A_05', '张天一*', '3-8,10-13周'
    ]),
    const OcrCell(row: 3, col: 4, lines: <String>['3-4节', '校本部3号教学楼3-510']),

    // 周五 1-2 节 与 5-6 节 同名（不能被合并成一门）
    const OcrCell(row: 0, col: 5, lines: <String>[
      '高等数学A(1)_04', '张怡通*', '第3周', '1-2节'
    ]),
    const OcrCell(row: 1, col: 5, lines: <String>['校本部4号教学楼4-101']),
    const OcrCell(row: 4, col: 5, lines: <String>[
      '高等数学A(1)_04', '张怡通*', '4-16周', '5-6节'
    ]),
    const OcrCell(row: 5, col: 5, lines: <String>['校本部3号教学楼3-210']),

    // 一格两门课（下午压缩列：第 1 门属本列，第 2 门属下一列）
    const OcrCell(row: 6, col: 1, lines: <String>[
      '形势与政策', '专业导论', '29', '01',
      '孙兴昌*', '孙昱楠*', '9-11周', '3-5周'
    ]),
    const OcrCell(row: 7, col: 1, lines: <String>[
      '7-8节', '7-8节', '校本部冷链大楼冷链-A204', '校本部冷链大楼冷链-A304'
    ]),
  ];
  return cells;
}

void main() {
  group('作息时间解析', () {
    test('12 节时间全部正确', () {
      final List<PeriodTime> periods = parseTimes(sampleCells());
      expect(periods.length, 12);
      expect(periods[0].startMinute, 8 * 60);
      expect(periods[0].endMinute, 8 * 60 + 45);
      expect(periods[11].startMinute, 20 * 60 + 30);
      expect(periods[11].endMinute, 21 * 60 + 15);
    });

    test('没有时间栏时给出警告', () {
      final List<OcrCell> onlyCourses = sampleCells()
          .where((OcrCell c) => c.col != 0)
          .toList();
      final CellParseResult r = parseSchedule(onlyCourses);
      expect(r.periods, isEmpty);
      expect(r.courses, isEmpty);
      expect(r.warnings, isNotEmpty);
    });
  });

  group('单格字段解析', () {
    test('课名 + 教师 + 周次 + 节次', () {
      final ParsedCell? p = parseCell(<String>[
        '高等数学A(1)_04', '张怡通*', '3-16周', '1-2节'
      ], 1);
      expect(p, isNotNull);
      expect(p!.name.contains('高等数学'), isTrue);
      expect(p.teacher, '张怡通*');
      expect(p.startWeek, 3);
      expect(p.endWeek, 16);
      expect(p.startPeriod, 1);
      expect(p.endPeriod, 2);
    });

    test('教室行不含课名（纯地点）', () {
      final ParsedCell? p = parseCell(<String>['校本部3号教学楼3-310'], 2);
      expect(p, isNotNull);
      expect(p!.hasName, isFalse);
      expect(p.room.contains('3-310'), isTrue);
    });

    test('两字课名不会被当成教师名', () {
      final ParsedCell? p = parseCell(<String>[
        '体育（1）_23', '杨学文*', '3-18周', '5-6节'
      ], 5);
      expect(p, isNotNull);
      expect(p!.name.contains('体育'), isTrue);
      expect(p.teacher, '杨学文*');
    });
  });

  group('课程组装', () {
    test('跨格子的教室能并入同一门课', () {
      final CellParseResult r = parseSchedule(sampleCells());
      final Course? c = r.courses
          .where((Course x) => x.name.contains('大学英语'))
          .cast<Course?>()
          .firstWhere((Course? x) => true, orElse: () => null);
      expect(c, isNotNull);
      expect(c!.weekday, 1, reason: '周一第1列');
      expect(c.startPeriod, 1);
      expect(c.endPeriod, 2);
      expect(c.room.contains('A202'), isTrue);
      expect(c.startWeek, 7);
      expect(c.endWeek, 8);
    });

    test('同名列、节次不相邻时是两门课', () {
      final CellParseResult r = parseSchedule(sampleCells());
      final List<Course> math =
          r.courses.where((Course c) => c.name.contains('高等数学')).toList();
      // 周二 1-2、周五 1-2、周五 5-6 = 3 门
      expect(math.length, 3);
      final List<String> spans =
          math.map((Course c) => '${c.weekday}:${c.startPeriod}-${c.endPeriod}').toList();
      expect(spans.contains('5:1-2'), isTrue);
      expect(spans.contains('5:5-6'), isTrue);
    });

    test('一格两门课拆开后星期错开', () {
      final CellParseResult r = parseSchedule(sampleCells());
      final Course? a = r.courses
          .where((Course c) => c.name.contains('形势与政策'))
          .cast<Course?>()
          .firstWhere((Course? x) => true, orElse: () => null);
      final Course? b = r.courses
          .where((Course c) => c.name.contains('专业导论'))
          .cast<Course?>()
          .firstWhere((Course? x) => true, orElse: () => null);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.weekday, 1, reason: '第 1 门属本列（周一）');
      expect(b!.weekday, 2, reason: '第 2 门属下一列（周二）');
      expect(a.startWeek, 9);
      expect(a.endWeek, 11);
      expect(b.startWeek, 3);
      expect(b.endWeek, 5);
    });

    test('所有课程的星期都在 1..7', () {
      final CellParseResult r = parseSchedule(sampleCells());
      for (final Course c in r.courses) {
        expect(c.weekday, inInclusiveRange(1, 7));
        expect(c.endPeriod, greaterThanOrEqualTo(c.startPeriod));
      }
    });

    test('课程排序按 星期 -> 节次', () {
      final CellParseResult r = parseSchedule(sampleCells());
      for (int i = 1; i < r.courses.length; i++) {
        final Course p = r.courses[i - 1];
        final Course q = r.courses[i];
        expect(p.weekday < q.weekday ||
            (p.weekday == q.weekday && p.startPeriod <= q.startPeriod), isTrue);
      }
    });
  });
}
