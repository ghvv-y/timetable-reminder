// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 无框线课表网格解析测试
//
// 输入是原生侧 BorderlessOcr 输出的 JSON 结构（用真实识别结果手工还原），
// 验证「按锚点落好格的碎文字」能正确拼成课程。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/ocr/grid_parser.dart';

/// 造一份贴近原生输出结构的网格
String sampleGridJson() {
  // rows: 12 个节次；days: 周一到周日
  final List<String> rows = <String>[
    '08:00-08:45', '08:50-09:35', '10:05-10:50', '10:55-11:40',
    '13:30-14:15', '14:20-15:05', '15:35-16:20', '16:25-17:10',
    '18:00-18:45', '18:50-19:35', '19:40-20:25', '20:30-21:15',
  ];
  final List<int> days = <int>[1, 2, 3, 4, 5, 6, 7];

  // grid[row][day][slot] = lines
  // 类型：行列表 -> 每天 -> 2 个子槽 -> 文字行
  final List<List<List<List<String>>>> g = <List<List<List<String>>>>[];
  for (int r = 0; r < rows.length; r++) {
    final List<List<List<String>>> rowCells = <List<List<String>>>[];
    for (int d = 0; d < days.length; d++) {
      rowCells.add(<List<String>>[<String>[], <String>[]]);
    }
    g.add(rowCells);
  }

  // 周一 1-2 节：课名在上半格，教室在下半格（跨节次行的典型形态）
  g[0][0][0] = <String>['大学英语（1）_33', '黄怡凡*', '7-8周', '1-2节'];
  g[1][0][0] = <String>['校本部冷链大楼冷链-A202'];

  // 周二 1-2 节：单格全字段
  g[0][1][0] = <String>['高等数学A(1)_04', '张怡通*', '3-16周', '1-2节'];
  g[1][1][0] = <String>['校本部3号教学楼3-310'];

  // 周一 7-8 节：压缩列 —— slot0 = 形势与政策，slot1 = 专业导论
  g[6][0][0] = <String>['形势与政策_29', '孙兴昌*', '9-11周', '7-8节'];
  g[7][0][0] = <String>['校本部冷链大楼冷链-A204'];
  g[6][0][1] = <String>['专业导论_01', '孙昱楠*', '3-5周', '7-8节'];
  g[7][0][1] = <String>['校本部冷链大楼冷链-A304'];

  // 周四 7-8 节：被拆成多段的课名
  g[6][3][0] = <String>['人工智能', '与信息技术基础A_05', '张天一*', '3-8,10-13周'];
  g[7][3][0] = <String>['3-4节', '校本部3号教学楼3-510'];

  final Map<String, Object?> root = <String, Object?>{
    'rows': rows,
    'days': days,
    'grid': g,
    'stats': <String, Object?>{'boxes': 100, 'placed': 30},
  };
  return jsonEncode(root);
}

void main() {
  group('子槽字段解析', () {
    test('课名 + 教师 + 周次 + 节次', () {
      final SlotFields f = parseSlotLines(<String>[
        '高等数学A(1)_04', '张怡通*', '3-16周', '1-2节'
      ]);
      expect(f.name, contains('高等数学'));
      expect(f.teacher, contains('张怡通'));
      expect(f.startPeriod, 1);
      expect(f.endPeriod, 2);
      expect(f.weeks.length, 1);
      expect(f.weeks.first.startWeek, 3);
    });

    test('只有教室的续行不算课名', () {
      final SlotFields f = parseSlotLines(<String>['校本部3号教学楼3-310']);
      expect(f.hasName, isFalse);
      expect(f.room, contains('3-310'));
    });

    test('被拆散的课名能拼回来', () {
      final SlotFields f = parseSlotLines(<String>[
        '人工智能', '与信息技术基础A_05', '张天一*', '3-8,10-13周'
      ]);
      expect(f.name, contains('人工智能'));
      expect(f.name, contains('信息技术基础'));
      expect(f.teacher, contains('张天一'));
    });

    test('两字课名不会被当成人名', () {
      final SlotFields f = parseSlotLines(<String>[
        '体育（1）_23', '杨学文*', '3-18周', '5-6节'
      ]);
      expect(f.name, contains('体育'));
      expect(f.teacher, contains('杨学文'));
    });
  });

  group('网格 JSON 解析', () {
    late GridParseResult r;

    setUpAll(() {
      r = parseGridJson(sampleGridJson());
    });

    test('作息时间解析成 12 节', () {
      expect(r.periods.length, 12);
      expect(r.periods.first.startMinute, 8 * 60);
      expect(r.periods.last.endMinute, 21 * 60 + 15);
    });

    test('课程被正确组装', () {
      // 大学英语 + 高等数学 + 形势与政策 + 专业导论 + 人工智能(3-8,10-13 拆 2 条) = 6
      expect(r.courses.length, 6);
    });

    test('跨节次行的教室并入同一门课', () {
      final Course c =
          r.courses.firstWhere((Course x) => x.name.contains('大学英语'));
      expect(c.weekday, 1);
      expect(c.startPeriod, 1);
      expect(c.endPeriod, 2);
      expect(c.room, contains('A202'));
      expect(c.startWeek, 7);
      expect(c.endWeek, 8);
    });

    test('压缩列两门课分属同一天', () {
      final Course a =
          r.courses.firstWhere((Course x) => x.name.contains('形势与政策'));
      final Course b =
          r.courses.firstWhere((Course x) => x.name.contains('专业导论'));
      expect(a.weekday, 1);
      expect(b.weekday, 1, reason: '压缩列第二门仍属于周一');
      expect(a.startWeek, 9);
      expect(b.startWeek, 3);
      expect(b.room, contains('A304'));
    });

    test('被拆散的课名与不连续周次', () {
      final List<Course> ai = r.courses
          .where((Course c) => c.name.contains('人工智能'))
          .toList();
      expect(ai, isNotEmpty);
      // 3-8,10-13 会被拆成两条
      expect(ai.length, 2);
      final Set<String> spans = ai
          .map((Course c) => '${c.startWeek}-${c.endWeek}')
          .toSet();
      expect(spans, <String>{'3-8', '10-13'});
      expect(ai.first.teacher, contains('张天一'));
    });

    test('星期与节次全部合法', () {
      for (final Course c in r.courses) {
        expect(c.weekday, inInclusiveRange(1, 7));
        expect(c.startPeriod, inInclusiveRange(1, 12));
        expect(c.endPeriod, greaterThanOrEqualTo(c.startPeriod));
      }
    });

    test('空网格不崩溃', () {
      final String emptyJson = jsonEncode(<String, Object?>{
        'rows': <String>[],
        'days': <int>[],
        'grid': <Object?>[],
      });
      final GridParseResult e = parseGridJson(emptyJson);
      expect(e.courses, isEmpty);
      expect(e.periods, isEmpty);
    });
  });
}
