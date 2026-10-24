// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 权限自检：一次性查清「短信 / 精确闹钟 / 通知 / 电池优化」四项状态
//
// 用途：
//   1. 首次启动时提示需要补哪个权限
//   2. 设置页「权限自检」按钮实时查看
//
// 说明：vivo、小米、华为等厂商的自启动、后台运行等开关没有统一接口，
// 无法程序化查询，只能给出引导文字。

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'alarm_scheduler.dart';

/// 单项权限的检查结果
class PermissionCheckItem {
  /// 名称
  final String name;

  /// 是否已满足
  final bool ok;

  /// 能自动查询到状态
  final bool known;

  /// 结果说明
  final String detail;

  /// 如何在系统里开启
  final String actionHint;

  /// 是否阻断短信发送（阻断项会突出显示）
  final bool critical;

  const PermissionCheckItem({
    required this.name,
    required this.ok,
    this.known = true,
    required this.detail,
    this.actionHint = '',
    this.critical = false,
  });

  static PermissionCheckItem unknown(String name, String detail) =>
      PermissionCheckItem(name: name, ok: false, known: false, detail: detail);
}

/// 一次性收集全部权限状态
Future<List<PermissionCheckItem>> collectPermissionChecks(String smsTo) async {
  final List<PermissionCheckItem> items = <PermissionCheckItem>[];

  // ---------- 1. 发送短信 ----------
  if (Platform.isWindows) {
    items.add(const PermissionCheckItem(
      name: '发送短信',
      ok: false,
      known: false,
      detail: '电脑端没有短信通道，到点只记录日志，不发送短信',
      actionHint: '提醒功能请在手机上使用',
    ));
  } else {
    final PermissionStatus sms = await Permission.sms.status;
    items.add(PermissionCheckItem(
      name: '发送短信',
      ok: sms.isGranted,
      detail: sms.isGranted
          ? '已授权，可以静默发送短信'
          : (sms.isPermanentlyDenied
              ? '已被永久拒绝，只能到系统设置里手动打开'
              : '未授权，到点无法发出短信'),
      actionHint: '系统设置 → 应用与权限 → 权限管理 → 课表提醒 → 发送短信',
      critical: true,
    ));
  }

  // ---------- 2. 精确闹钟 ----------
  final ExactAlarmStatus exact = await AlarmScheduler.status();
  switch (exact) {
    case ExactAlarmStatus.granted:
      items.add(const PermissionCheckItem(
        name: '精确闹钟',
        ok: true,
        detail: '已授权，提醒能精确到分钟',
      ));
      break;
    case ExactAlarmStatus.notRequired:
      items.add(const PermissionCheckItem(
        name: '精确闹钟',
        ok: true,
        detail: '系统版本低于 Android 12，安装即授权，无需设置',
      ));
      break;
    case ExactAlarmStatus.denied:
      items.add(const PermissionCheckItem(
        name: '精确闹钟',
        ok: false,
        detail: '被系统限制，提醒可能被推迟数分钟（vivo 等机型可能没有这个开关，'
            '系统会默认放行，可点「申请精确闹钟权限」试一下）',
        actionHint: '点下方按钮尝试跳转；部分机型无此开关，属正常',
        critical: true,
      ));
      break;
    case ExactAlarmStatus.unsupported:
      items.add(PermissionCheckItem.unknown(
        '精确闹钟',
        Platform.isWindows ? '电脑端不需要精确闹钟权限' : '无法查询（不影响使用）',
      ));
      break;
  }

  // ---------- 3. 通知 ----------
  if (!Platform.isWindows) {
    final PermissionStatus notif = await Permission.notification.status;
    items.add(PermissionCheckItem(
      name: '通知',
      ok: notif.isGranted,
      known: !notif.isPermanentlyDenied,
      detail: notif.isGranted
          ? '已授权，短信到达手机后能正常同步到手表'
          : '建议授权：短信到达手机后需要通知才能同步显示到手表',
      actionHint: '系统设置 → 应用与权限 → 通知 → 课表提醒 → 允许通知',
      critical: true,
    ));
  }

  // ---------- 4. 读取 SIM 卡 ----------
  //
  // 【为什么需要】SubscriptionManager.getActiveSubscriptionInfoList()
  // 没有 READ_PHONE_STATE 就返回空列表，表现为设置页「发送用哪张卡」
  // 读不到卡、也没得选；双卡手机上就只能用不确定的默认卡发送，
  // 很容易出现「到点了但短信发不出去」。
  if (!Platform.isWindows) {
    final PermissionStatus phone = await Permission.phone.status;
    items.add(PermissionCheckItem(
      name: '读取 SIM 卡',
      ok: phone.isGranted,
      detail: phone.isGranted
          ? '已授权，可以在设置里指定用哪张卡发送'
          : '未授权：设置页读不到 SIM 卡，双卡手机可能发不出短信',
      actionHint: '系统设置 → 应用与权限 → 权限管理 → 课表提醒 → 电话/电话信息',
      critical: true,
    ));
  }

  // ---------- 5. 接收号码 ----------
  items.add(PermissionCheckItem(
    name: '短信接收号码',
    ok: smsTo.trim().isNotEmpty,
    detail: smsTo.trim().isEmpty
        ? '还没填号码，闹钟到点不会发出任何短信'
        : '已填写：$smsTo',
    actionHint: '在上面的输入框里填写你自己的手机号',
    critical: true,
  ));

  return items;
}

/// 一次性申请：短信 + 通知 + 精确闹钟，返回结果摘要
///
/// [onSmsChanged] 在短信权限申请完成后回调，用于把结果写回设置。
Future<String> performPermissionRequests({
  required Future<void> Function() onSmsChanged,
}) async {
  if (Platform.isWindows) return '电脑端无需权限';

  final Map<Permission, PermissionStatus> res = await <Permission>[
    Permission.sms,
    Permission.notification,
    // 读取 SIM 卡：双卡手机必须要有，否则选不了卡、可能发不出短信
    Permission.phone,
  ].request();

  await onSmsChanged();

  // 精确闹钟走原生跳转（跳不过去会自动回退到应用详情页）
  final String? landed = await AlarmScheduler.requestExactAlarmPermission();

  final StringBuffer sb = StringBuffer();
  final bool smsOk = res[Permission.sms]?.isGranted ?? false;
  final bool notifOk = res[Permission.notification]?.isGranted ?? false;
  final bool phoneOk = res[Permission.phone]?.isGranted ?? false;
  sb.write('短信：${smsOk ? '已授权' : '未授权'}');
  sb.write('，通知：${notifOk ? '已授权' : '未授权'}');
  sb.write('，读取SIM卡：${phoneOk ? '已授权' : '未授权'}');
  switch (landed) {
    case 'granted':
      sb.write('，精确闹钟：已授权');
      break;
    case 'exact_alarm':
      sb.write('，已打开精确闹钟设置页，请手动允许');
      break;
    case 'app_details':
      sb.write('，该机型没有精确闹钟开关，已打开应用设置页');
      break;
    default:
      sb.write('，精确闹钟：无法跳转');
      break;
  }
  return sb.toString();
}
