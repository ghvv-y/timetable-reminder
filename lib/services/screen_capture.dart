// 屏幕截取（悬浮球）通道
//
// 用户开启后，悬浮球会浮在任意应用之上；点一下即截取当前屏幕，
// 截图路径通过 onScreenCaptured 回调返回，交给识别流程处理。
//
// 说明：本功能按需开启。开启期间系统会显示常驻通知与录制图标（系统强制），
// 关闭后立即消失，不影响「闹钟到点绝对静默」。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenCapture {
  static const MethodChannel _channel =
      MethodChannel('timetable_app/screen');

  /// 截屏完成回调：参数为截图文件路径，失败时为 null
  static void Function(String? path)? onCaptured;

  /// 截屏功能出错回调：参数为原因标识
  static void Function(String reason)? onError;

  /// 是否支持（仅 Android）
  static bool get isSupported => !Platform.isWindows;

  /// 注册通道回调（应用启动时调用一次）
  static void init() {
    _channel.setMethodCallHandler((MethodCall call) async {
      final Map<Object?, Object?>? args =
          call.arguments as Map<Object?, Object?>?;
      switch (call.method) {
        case 'onScreenCaptured':
          onCaptured?.call(args?['path'] as String?);
          break;
        case 'onCaptureError':
          onError?.call((args?['reason'] as String?) ?? 'unknown');
          break;
      }
      return null;
    });
  }

  /// 把原因标识翻译成用户能看懂的提示
  static String describeError(String reason) {
    if (reason.startsWith('foreground_failed')) {
      return '系统拒绝了截屏后台服务，请在系统设置里允许本应用后台运行后重试';
    }
    if (reason.startsWith('overlay_failed')) {
      return '悬浮球添加失败，请确认已允许「显示在其他应用上层」';
    }
    if (reason.startsWith('projection_failed')) {
      return '屏幕投影建立失败：$reason\n请关闭开关后重新开启一次';
    }
    if (reason == 'projection_null') {
      return '系统没给到屏幕投影对象，请关闭开关后重新开启';
    }
    if (reason == 'no_projection') {
      return '投影还没准备好（可能刚开启就点了）。请等两秒再点悬浮球';
    }
    if (reason == 'no_permission') {
      return '没有获得截屏授权';
    }
    return '截屏功能启动失败：$reason';
  }

  /// 是否已获得「显示在其他应用上层」权限
  static Future<bool> canDrawOverlay() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await _channel.invokeMethod<bool>('canDrawOverlay');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 悬浮球是否正在运行
  static Future<bool> isRunning() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await _channel.invokeMethod<bool>('isRunning');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 读取原生侧诊断日志（悬浮球排查用）
  static Future<String> readDiagnostics() async {
    if (!isSupported) return '（电脑端无此项）';
    try {
      final String? s =
          await _channel.invokeMethod<String>('readDiagnostics');
      return (s == null || s.trim().isEmpty) ? '（暂无记录）' : s;
    } catch (_) {
      return '（读取失败）';
    }
  }

  /// 清空诊断日志
  static Future<void> clearDiagnostics() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearDiagnostics');
    } catch (_) {}
  }

  /// 跳转到「显示在其他应用上层」授权页
  static Future<void> requestOverlayPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestOverlayPermission');
    } catch (_) {}
  }

  /// 开启悬浮球：会先要求悬浮窗权限，再弹出系统截屏授权
  ///
  /// 返回 true 表示授权成功且服务已启动。
  static Future<bool> start() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await _channel.invokeMethod<bool>('start');
      return ok == true;
    } on PlatformException catch (e) {
      debugPrint('开启屏幕识别失败: ${e.code} / ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 关闭悬浮球
  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// 截屏完成后是否自动返回课表界面
  static Future<bool> getAutoReturn() async {
    if (!isSupported) return false;
    try {
      final bool? v = await _channel.invokeMethod<bool>('getAutoReturn');
      return v ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 设置「截屏后自动返回」
  static Future<void> setAutoReturn(bool value) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(
          'setAutoReturn', <String, Object>{'value': value});
    } catch (_) {}
  }
}
