// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 闹钟调度：把每条启用的闹钟注册成系统精确闹钟
//
// 到点时由系统唤醒原生接收器，读取预先写入的「备注原文」并静默发送短信。
// 全程不发本机通知、不响铃、不震动。

import 'dart:io';

import 'package:flutter/services.dart';

/// 精确闹钟权限状态
enum ExactAlarmStatus {
  /// 已授权
  granted,

  /// 被系统限制（Android 12+ 未获得）
  denied,

  /// 系统版本低于 Android 12，安装即授权，无需处理
  notRequired,

  /// 非 Android 平台或查询失败
  unsupported,
}

/// 闹钟健康状态
class AlarmHealth {
  /// 配置里有几条闹钟
  final int configured;

  /// 系统里真正还挂着几条
  final int alive;

  /// 系统「下一个闹钟」的时间戳（毫秒），-1 表示没有
  final int nextTrigger;

  /// 当前第几周，-1 表示算不出来（没设学期开始日）
  final int week;

  /// 通知权限是否已开
  ///
  /// Android 13+ 没这个权限时 notify() 是**静默失败**（不抛异常也不显示），
  /// 必须在界面上明确告诉用户，否则他会以为「闹钟没响」。
  final bool notifEnabled;

  /// 当前提醒方式（both / notify / sms）
  final String mode;

  const AlarmHealth({
    required this.configured,
    required this.alive,
    required this.nextTrigger,
    required this.week,
    this.notifEnabled = true,
    this.mode = 'both',
  });

  /// 系统里的闹钟是不是被清掉了
  ///
  /// 注册过的闹钟一定会有 PendingIntent；被系统清掉后会一起消失。
  bool get looksCleared => configured > 0 && alive == 0;

  /// 周次是否已配置（没配的话起止周过滤不生效）
  bool get weekKnown => week > 0;

  /// 提醒方式是否包含通知
  bool get wantsNotify => mode != 'sms';
}

class AlarmScheduler {
  static const MethodChannel _channel =
      MethodChannel('timetable_app/alarm');

  /// 是否支持系统精确闹钟（仅 Android）
  static bool get isSupported => !Platform.isWindows;

  /// 查询精确闹钟权限状态
  static Future<ExactAlarmStatus> status() async {
    if (!isSupported) return ExactAlarmStatus.unsupported;
    try {
      final String? s = await _channel.invokeMethod<String>('exactAlarmStatus');
      switch (s) {
        case 'granted':
          return ExactAlarmStatus.granted;
        case 'denied':
          return ExactAlarmStatus.denied;
        case 'na':
          return ExactAlarmStatus.notRequired;
        default:
          return ExactAlarmStatus.unsupported;
      }
    } catch (_) {
      return ExactAlarmStatus.unsupported;
    }
  }

  /// 兼容旧调用：是否已获得（或无需）精确闹钟权限
  static Future<bool> canScheduleExactAlarms() async {
    final ExactAlarmStatus s = await status();
    return s == ExactAlarmStatus.granted || s == ExactAlarmStatus.notRequired;
  }

  /// 读取原生诊断日志（闹钟注册/触发/发送都记在里面）
  static Future<String> readDiagnostics() async {
    if (!isSupported) return '（电脑端无此项）';
    try {
      final String? s = await _channel.invokeMethod<String>('readDiag');
      return (s == null || s.trim().isEmpty) ? '' : s;
    } catch (_) {
      return '（读取失败）';
    }
  }

  /// 清空诊断日志
  static Future<void> clearDiagnostics() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearDiag');
    } catch (_) {}
  }

  /// 最近一次短信发送失败（没有失败时返回 null）
  ///
  /// 「闹钟到点没收到短信」是致命问题，必须在界面上直接提示，
  /// 不能只写在日志里等用户自己去看。
  static Future<String?> lastSmsFailure() async {
    if (!isSupported) return null;
    try {
      final Object? r = await _channel.invokeMethod<Object>('lastSmsFailure');
      if (r is Map && r['msg'] != null) return r['msg'].toString();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 清除失败标记
  static Future<void> clearSmsFailure() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearSmsFailure');
    } catch (_) {}
  }

  /// 立即弹一条测试通知（验证提醒通道，不用等闹钟到点）
  static Future<void> testNotification(String text) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>(
        'testNotification', <String, Object>{'text': text});
    } catch (_) {}
  }

  /// 闹钟健康自检
  ///
  /// 实测出现过「刚装好能响，过一两天就再也不响，日志里连触发都没有」——
  /// 那是系统把闹钟清掉了（国产 ROM 冻结长期不用的应用会这样）。
  /// 这个自检把「配置里几条」和「系统里还真挂着几条」摆出来，一眼可判断。
  static Future<AlarmHealth> health() async {
    if (!isSupported) {
      return const AlarmHealth(
          configured: 0, alive: 0, nextTrigger: -1, week: -1);
    }
    try {
      final Object? r = await _channel.invokeMethod<Object>('alarmHealth');
      if (r is Map) {
        return AlarmHealth(
          configured: (r['configured'] as num?)?.toInt() ?? 0,
          alive: (r['alive'] as num?)?.toInt() ?? 0,
          nextTrigger: (r['nextTrigger'] as num?)?.toInt() ?? -1,
          week: (r['week'] as num?)?.toInt() ?? -1,
          notifEnabled: r['notifEnabled'] != false,
          mode: (r['mode'] ?? 'both').toString(),
        );
      }
    } catch (_) {}
    return const AlarmHealth(
        configured: 0, alive: 0, nextTrigger: -1, week: -1);
  }

  /// 申请精确闹钟权限。
  ///
  /// 原生侧在官方设置页跳不过去时会自动回退到本应用的系统设置页，
  /// 返回实际落到的页面标识：
  ///   granted     已授权，无需跳转
  ///   exact_alarm 跳到了精确闹钟设置页
  ///   app_details 回退到了应用详情页
  ///   null        全都失败
  static Future<String?> requestExactAlarmPermission() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('requestExactAlarmPermission');
    } catch (_) {
      return null;
    }
  }

  /// 打开本应用的系统设置页
  static Future<String?> openAppSettings() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('openAppSettings');
    } catch (_) {
      return null;
    }
  }

  /// 取消全部已注册闹钟
  static Future<void> cancelAll() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } catch (_) {}
  }

  /// 重新注册全部闹钟
  ///
  /// [subscriptionId] 指定用哪张 SIM 卡发短信；-1 表示不指定。
  /// [mode] 提醒方式：both=通知+短信 / notify=仅通知 / sms=仅短信。
  /// [termStart] 学期开始日（yyyy-MM-dd）。原生侧用它算出「今天第几周」，
  ///   从而跳过本周没课的闹钟；为空则不做周次过滤。
  /// [weekOverride] 手动指定当前周次（0 表示按日期自动算）。
  static Future<void> rescheduleAll({
    required List<Map<String, Object?>> alarms,
    required String smsTo,
    int subscriptionId = -1,
    String mode = 'both',
    String termStart = '',
    int weekOverride = 0,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('rescheduleAll', <String, Object>{
        'alarms': alarms,
        'to': smsTo,
        'subscriptionId': subscriptionId,
        'mode': mode,
        'termStart': termStart,
        'weekOverride': weekOverride,
      });
    } catch (_) {}
  }
}
