// 词典纠正测试
//
// 场景：用户已经用「粘贴导入」拿到 100% 准确的课表，
// 之后用截图识别时，用这份课表纠正 OCR 的错字。

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/ocr/course_dictionary.dart';

List<Course> sampleCourses() => <Course>[
      const Course(
        id: '1', name: '人工智能与信息技术基础A_05', weekday: 4,
        startPeriod: 3, endPeriod: 4, teacher: '张天一*', room: '校本部3号教学楼3-510',
      ),
      const Course(
        id: '2', name: '高等数学A(1)_04', weekday: 2,
        startPeriod: 1, endPeriod: 2, teacher: '张怡通*', room: '校本部3号教学楼3-310',
      ),
      const Course(
        id: '3', name: '马克思主义基本原理_08', weekday: 2,
        startPeriod: 3, endPeriod: 4, teacher: '崔昕昕*', room: '校本部4号教学楼4-506',
      ),
      const Course(
        id: '4', name: '大学英语（1）_33', weekday: 1,
        startPeriod: 1, endPeriod: 2, teacher: '黄怡凡*', room: '校本部冷链大楼冷链-A202',
      ),
    ];

void main() {
  group('相似度', () {
    test('完全相同是 1', () {
      expect(similarity('高等数学', '高等数学'), 1.0);
    });

    test('前缀关系得分较高', () {
      expect(similarity('人工智', '人工智能与信息技术基础A_05'), greaterThan(0.6));
    });

    test('完全无关得分低', () {
      expect(similarity('体育', '高等数学'), lessThan(0.4));
    });
  });

  group('词典构建', () {
    test('从课程里抽出课名/教师/地点', () {
      final CourseDictionary d = CourseDictionary.fromCourses(sampleCourses());
      expect(d.names.length, 4);
      expect(d.teachers.length, 4);
      expect(d.rooms.length, 4);
      expect(d.isEmpty, isFalse);
    });

    test('空列表不崩', () {
      final CourseDictionary d = CourseDictionary.fromCourses(<Course>[]);
      expect(d.isEmpty, isTrue);
    });
  });

  group('模糊匹配', () {
    late CourseDictionary dict;

    setUp(() {
      dict = CourseDictionary.fromCourses(sampleCourses());
    });

    test('OCR 碎片能匹配到完整课名', () {
      final MatchResult? m = dict.matchName('人工智');
      expect(m, isNotNull);
      expect(m!.value, contains('人工智能'));
    });

    test('教师名带标点也能匹配', () {
      final MatchResult? m = dict.matchTeacher('崔昕昕');
      expect(m, isNotNull);
      expect(m!.value, contains('崔昕昕'));
    });

    test('教室号能匹配', () {
      final MatchResult? m = dict.matchRoom('校本部3号教学楼3-510');
      expect(m, isNotNull);
    });

    test('完全不相关的不硬匹配', () {
      final MatchResult? m = dict.matchName('体育');
      expect(m, isNull, reason: '词典里没有体育，不应该硬凑一个');
    });

    test('太短的碎片不匹配', () {
      final MatchResult? m = dict.matchName('人');
      expect(m, isNull);
    });
  });

  group('纠正流程', () {
    late DictionaryCorrector corrector;

    setUp(() {
      corrector = DictionaryCorrector(
          CourseDictionary.fromCourses(sampleCourses()));
    });

    test('课名被修正时留下记录', () {
      final r = corrector.correct(name: '人工智', teacher: '', room: '');
      expect(r.name, contains('人工智能'));
      expect(r.fixes.length, 1);
      expect(r.fixes.first.field, 'name');
      expect(r.fixes.first.from, '人工智');
    });

    test('已经正确的不会被反复改写', () {
      final r = corrector.correct(
          name: '高等数学A(1)_04', teacher: '张怡通*', room: '校本部3号教学楼3-310');
      expect(r.fixes, isEmpty);
      expect(r.name, '高等数学A(1)_04');
    });

    test('多个字段同时修正', () {
      final r = corrector.correct(name: '人工智', teacher: '张天', room: '');
      expect(r.name, contains('人工智能'));
      expect(r.teacher, '张天一*');
      expect(r.fixes.length, 2);
    });
  });
}
