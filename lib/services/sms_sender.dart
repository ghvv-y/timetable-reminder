// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 静默短信发送：只发短信，不响铃、不震动、不弹通知
//
// 双卡处理：
// 不指定卡时，系统会弹出「选择 SIM 卡」对话框——这会破坏「到点静默」的前提。
// 因此这里支持传入 subscriptionId（在设置页选定），让系统直接走指定卡。
//
// Android：通过平台通道调用系统短信接口（SmsManager）。
// Windows / 其他平台：平台通道不可用，返回 false 并写入发送日志。

import 'dart:io';

import 'package:flutter/services.dart';

import '../model/models.dart';

class SmsSender {
  static const MethodChannel _channel =
      MethodChannel('timetable_app/sms');

  /// 是否支持短信（仅 Android）
  static bool get isSupported => !Platform.isWindows;

  /// 列出手机上的 SIM 卡
  ///
  /// 用于设置页让用户指定「用哪张卡发」，避免每次发送都弹选卡框。
  static Future<List<SimCard>> listSimCards() async {
    if (!isSupported) return <SimCard>[];
    try {
      final List<Object?>? raw =
          await _channel.invokeMethod<List<Object?>>('listSimCards');
      if (raw == null) return <SimCard>[];
      final List<SimCard> out = <SimCard>[];
      for (final Object? item in raw) {
        if (item is Map) {
          final SimCard? sim = SimCard.fromMap(Map<String, Object?>.from(item));
          if (sim != null) out.add(sim);
        }
      }
      return out;
    } catch (_) {
      return <SimCard>[];
    }
  }

  /// 发送短信。注意：[message] 就是正文，不做任何拼接与改写。
  ///
  /// [subscriptionId] 指定用哪张卡；传 -1 则由系统决定（可能弹选卡框）。
  /// 返回 true 表示已交给系统发出。
  static Future<bool> send({
    required String to,
    required String message,
    int subscriptionId = -1,
  }) async {
    if (to.trim().isEmpty || message.isEmpty) return false;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // 电脑端没有短信通道，静默跳过（不弹窗打扰）
      return false;
    }

    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'sendSms',
        <String, Object>{
          'to': to.trim(),
          'message': message,
          'subscriptionId': subscriptionId,
        },
      );
      return ok == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
