// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 粘贴课表文本解析测试
//
// 测试数据是真实从 URP 教务系统网页复制出来的文本（已去除个人信息），
// 所以这组测试同时也是「解析器面对真实输入」的验收。

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/ocr/paste_parser.dart';

/// 真实 URP「全部课程清单」片段（截取前 5 门课，保留原始格式）
const String urpSample = '''
2026-2027学年秋学期学生课表
节次/时间	星期一	星期二	星期三	星期四	星期五	星期六	星期日
第(08:00-08:45)							
第(08:50-09:35)							
第(10:05-10:50)							
第(10:55-11:40)							
第(13:30-14:15)							
第(14:20-15:05)							
第(15:35-16:20)							
第(16:25-17:10)							
第(18:00-18:45)							
第(18:50-19:35)							
第(19:40-20:25)							
第(20:30-21:15)							
全部课程清单
2640706001	高等数学A(1)			04	6	必修	数学与自然科学类	考试	张怡通*	正常	置入	3-16周>>星期二>>1-2节	校本部>>3号教学楼>>3-310
3-16周>>星期三>>1-2节	校本部>>3号教学楼>>3-210
3-8周>>星期四>>7-8节	校本部>>冷链大楼>>冷链-B219
第3周>>星期五>>1-2节	校本部>>4号教学楼>>4-101
4-16周>>星期五>>5-6节	校本部>>3号教学楼>>3-210
2640222001	健康教育			01	2	必修	训练与健康类	考查	艾娟* 王丛	正常	置入	9-13周>>星期一>>9-12节	校本部>>科学会堂>>报告厅
2641703002	马克思主义基本原理			08	3	必修	人文与社会科学类	考试	崔昕昕*	正常	置入	3-12周>>星期二>>3-4节	校本部>>4号教学楼>>4-506
3-12周>>星期四>>1-2节	校本部>>4号教学楼>>4-506
2640442103	工程图学B（1）			03	2	必修	学科基础课	考试	李帅*	正常	置入	3-4,6-10周>>星期一>>3-4节	校本部>>1号教学楼>>1-702
第7周>>星期一>>9-10节	校本部>>1号教学楼>>1-702
3-10周>>星期三>>3-4节	校本部>>1号教学楼>>1-702
2641302001	大学英语（1）			33	2	必修	共同基础课	考试	黄怡凡*	正常	置入	7-8周>>星期一>>1-2节	校本部>>冷链大楼>>冷链-A202
3,5,7,9,11,13,15周>>星期二>>7-8节	校本部>>2号教学楼>>2-304
4,6,8,10,12,14,16周>>星期二>>7-8节	校本部>>7号教学楼>>7-201
''';

void main() {
  group('周次解析', () {
    test('普通区间', () {
      final List<WeekSpec> w = parseWeekExpr('3-16周');
      expect(w.length, 1);
      expect(w.first.startWeek, 3);
      expect(w.first.endWeek, 16);
      expect(w.first.weekType, 'all');
    });

    test('不连续区间会拆成多条', () {
      final List<WeekSpec> w = parseWeekExpr('3-4,6-10周');
      expect(w.length, 2);
      expect(w[0].startWeek, 3);
      expect(w[0].endWeek, 4);
      expect(w[1].startWeek, 6);
      expect(w[1].endWeek, 10);
    });

    test('单周列表 → odd', () {
      final List<WeekSpec> w = parseWeekExpr('3,5,7,9,11,13,15周');
      expect(w.length, 1);
      expect(w.first.weekType, 'odd');
      expect(w.first.startWeek, 3);
      expect(w.first.endWeek, 15);
    });

    test('双周列表 → even', () {
      final List<WeekSpec> w = parseWeekExpr('4,6,8,10,12,14,16周');
      expect(w.length, 1);
      expect(w.first.weekType, 'even');
      expect(w.first.startWeek, 4);
      expect(w.first.endWeek, 16);
    });

    test('单个周次', () {
      final List<WeekSpec> w = parseWeekExpr('第7周');
      expect(w.length, 1);
      expect(w.first.startWeek, 7);
      expect(w.first.endWeek, 7);
    });

    test('单周列表被截断时按学期末补齐', () {
      // 真实 OCR 里逗号容易丢，只剩 3,5,7,9
      final List<WeekSpec> w = parseWeekExpr('3,5,7,9', semesterMax: 16);
      expect(w.length, 1);
      expect(w.first.weekType, 'odd');
      expect(w.first.endWeek, 15, reason: '16 周学期里的最后一个单周是 15');
    });

    test('3 项的短列表不推断成单周（避免多生成提醒）', () {
      // 真实课表可能真的只在 3,5,7 周上课
      final List<WeekSpec> w = parseWeekExpr('3,5,7', semesterMax: 16);
      expect(w.length, 3, reason: '短列表应当拆成三个单周，而不是 3-15 单周');
      expect(w.map((WeekSpec x) => x.startWeek).toList(), <int>[3, 5, 7]);
    });

    test('截断补齐时会给出警告', () {
      final List<String> warn = <String>[];
      parseWeekExpr('3,5,7,9', semesterMax: 16, warnings: warn);
      expect(warn, isNotEmpty);
      expect(warn.first, contains('请核对'));
    });

    test('完整单双周列表不会误报警告', () {
      final List<String> warn = <String>[];
      parseWeekExpr('3,5,7,9,11,13,15周', semesterMax: 16, warnings: warn);
      expect(warn, isEmpty);
    });
  });

  group('URP 格式解析', () {
    late PasteParseResult result;

    setUpAll(() {
      final PasteParseResult? r = parsePastedSchedule(urpSample);
      expect(r, isNotNull, reason: '真实 URP 文本必须能解析');
      result = r!;
    });

    test('命中 URP 规则', () {
      expect(result.format, contains('URP'));
    });

    test('课程数量正确（工程图学拆 2 段、大学英语拆单双周）', () {
      // 高等数学 5 条 + 健康教育 1 + 马克思 2 + 工程图学 3(其中 3-4,6-10 拆成 2 条 → 共 4)
      // + 大学英语 3(其中单周/双周各 1) = 5+1+2+4+3 = 15
      expect(result.courses.length, 15);
    });

    test('课名/教师/教室/星期/节次都对', () {
      final Course math = result.courses.firstWhere(
        (Course c) => c.name.contains('高等数学') && c.weekday == 2,
      );
      expect(math.teacher, '张怡通*');
      expect(math.startPeriod, 1);
      expect(math.endPeriod, 2);
      expect(math.startWeek, 3);
      expect(math.endWeek, 16);
      expect(math.room, contains('3-310'));
    });

    test('第3周这种单周不会当成区间', () {
      final List<Course> friday = result.courses
          .where((Course c) => c.name.contains('高等数学') && c.weekday == 5)
          .toList();
      expect(friday.length, 2, reason: '周五有两门高数：第3周 和 4-16周');
      final Course w3 = friday.firstWhere((Course c) => c.startWeek == 3);
      expect(w3.endWeek, 3);
    });

    test('单双周被正确识别', () {
      final List<Course> en = result.courses
          .where((Course c) => c.name.contains('大学英语') && c.weekday == 2)
          .toList();
      expect(en.length, 2);
      final Course odd = en.firstWhere((Course c) => c.weekType == 'odd');
      final Course even = en.firstWhere((Course c) => c.weekType == 'even');
      expect(odd.startWeek, 3);
      expect(odd.endWeek, 15);
      expect(even.startWeek, 4);
      expect(even.endWeek, 16);
    });

    test('不连续周次拆成两条课程', () {
      final List<Course> gd = result.courses
          .where((Course c) =>
              c.name.contains('工程图学') && c.weekday == 1 && c.startPeriod == 3)
          .toList();
      expect(gd.length, 2, reason: '3-4周 和 6-10周 要拆开');
      expect(gd.map((Course c) => '${c.startWeek}-${c.endWeek}').toSet(),
          <String>{'3-4', '6-10'});
    });

    test('两个教师的字段能保留', () {
      final Course h = result.courses.firstWhere(
        (Course c) => c.name.contains('健康教育'),
      );
      expect(h.teacher, contains('艾娟'));
      expect(h.room, contains('科学会堂'));
    });

    test('星期全部合法', () {
      for (final Course c in result.courses) {
        expect(c.weekday, inInclusiveRange(1, 7));
        expect(c.endPeriod, greaterThanOrEqualTo(c.startPeriod));
      }
    });

    test('作息时间从文本里的 第(HH:MM-HH:MM) 解析出来', () {
      expect(result.periods.length, 12);
      expect(result.periods.first.startMinute, 8 * 60);
      expect(result.periods.last.endMinute, 21 * 60 + 15);
    });
  });

  group('通用格式兜底', () {
    test('一行一门课也能解析', () {
      const String generic = '''
大学英语（1）_33  黄怡凡  周一 1-2节 7-8周  冷链-A202
高等数学A(1)_04  张怡通  周二 1-2节 3-16周  3号教学楼3-310
马克思主义基本原理_08  崔昕昕  周二 3-4节 3-12周  4号教学楼4-506
''';
      final PasteParseResult? r = parsePastedSchedule(generic);
      expect(r, isNotNull);
      expect(r!.courses.length, greaterThanOrEqualTo(3));
      final Course c = r.courses.firstWhere((Course x) => x.weekday == 2);
      expect(c.startPeriod, 1);
    });

    test('地点比课名长也不会抢课名', () {
      const String generic = '''
体育 校本部体育场风雨操场1楼羽毛球馆 周一 5-6节 3-18周
大学英语 校本部冷链大楼冷链-A202 周二 1-2节 7-8周
''';
      final PasteParseResult? r = parsePastedSchedule(generic);
      expect(r, isNotNull);
      final Course c = r!.courses.firstWhere((Course x) => x.weekday == 1);
      expect(c.name, contains('体育'));
      expect(c.name, isNot(contains('操场')));
    });

    test('乱七八糟的文本返回 null', () {
      expect(parsePastedSchedule('今天天气不错，出门记得带伞。'), isNull);
      expect(parsePastedSchedule(''), isNull);
    });
  });

  group('剪贴板制表符被转成空格时', () {
    // 部分安卓机型复制网页时会把 \t 变成空格——必须能扛住
    test('URP 文本空格分隔也能解析', () {
      final String spaced = urpSample
          .replaceAll('\t', '  ')
          .replaceAll(RegExp(r'  +'), '  ');
      final PasteParseResult? r = parsePastedSchedule(spaced);
      expect(r, isNotNull, reason: '空格分隔的 URP 文本必须能解析');
      expect(r!.courses, isNotEmpty);
      final Course math = r.courses.firstWhere(
        (Course c) => c.name.contains('高等数学') && c.weekday == 2,
      );
      expect(math.teacher, '张怡通*');
      expect(math.startWeek, 3);
      expect(math.endWeek, 16);
    });
  });
}
