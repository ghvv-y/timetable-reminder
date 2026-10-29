// 输入校验 + 短信开关语义的测试
//
// 这批修复都来自外部审查报告，每条都必须有回归保护 ——
// 否则下次改坏还是"测试全绿但功能坏"。

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/utils/validators.dart';

void main() {
  group('结束节次不能小于开始节次', () {
    test('正常区间保持不变', () {
      expect(clampEndPeriod(3, 4), 4);
      expect(clampEndPeriod(1, 12), 12);
      expect(clampEndPeriod(5, 5), 5);
    });

    test('倒置区间被夹到开始节次', () {
      // 课表页按 (end - start + 1) * 行高 算课程块高度，倒置会算出负高度
      expect(clampEndPeriod(5, 2), 5);
      expect(clampEndPeriod(12, 1), 12);
    });
  });

  group('按星期闹钟必须选星期', () {
    test('weekly 且为空 → 不合法', () {
      expect(isValidAlarmWeekdays('weekly', <int>[]), isFalse);
    });

    test('weekly 有值 → 合法', () {
      expect(isValidAlarmWeekdays('weekly', <int>[1, 3]), isTrue);
    });

    test('once / daily 不需要星期', () {
      expect(isValidAlarmWeekdays('once', <int>[]), isTrue);
      expect(isValidAlarmWeekdays('daily', <int>[]), isTrue);
    });
  });

  group('作息时间必须结束晚于开始', () {
    test('正常', () {
      expect(isValidPeriodRange(8 * 60, 8 * 60 + 45), isTrue);
    });

    test('相等或倒置都不合法', () {
      expect(isValidPeriodRange(8 * 60, 8 * 60), isFalse);
      expect(isValidPeriodRange(9 * 60, 8 * 60), isFalse);
    });
  });

  group('短信总开关（smsEnabled）', () {
    test('开关打开时按用户选的模式走', () {
      expect(const AppSettings(smsEnabled: true, reminderMode: 'both')
          .effectiveReminderMode, 'both');
      expect(const AppSettings(smsEnabled: true, reminderMode: 'sms')
          .effectiveReminderMode, 'sms');
      expect(const AppSettings(smsEnabled: true, reminderMode: 'notify')
          .effectiveReminderMode, 'notify');
    });

    test('开关关闭时一律降级为仅通知', () {
      // 关键回归点：早先调度只读 reminderMode，这个开关根本没被读过，
      // 用户关了短信照样发、照样扣费。
      for (final String mode in <String>['both', 'sms', 'notify']) {
        final AppSettings s = AppSettings(smsEnabled: false, reminderMode: mode);
        expect(s.effectiveReminderMode, 'notify',
            reason: 'smsEnabled=false 时 $mode 必须降级为仅通知');
        expect(s.willSendSms, isFalse);
      }
    });

    test('选仅短信且开关打开时确实会发短信', () {
      const AppSettings s = AppSettings(smsEnabled: true, reminderMode: 'sms');
      expect(s.willSendSms, isTrue);
    });
  });
}
