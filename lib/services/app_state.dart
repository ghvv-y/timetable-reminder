// 全局应用状态：课程、作息时间、闹钟、设置、短信日志
//
// 统一在这里维护，界面只读状态、只调方法，保证手机与电脑两端行为一致。
// 数据持久化交给 Storage（JSON 文档存储），这里只负责业务规则。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../model/models.dart';
import '../model/period_time.dart';
import '../ocr/table_parser.dart';
import '../utils/time_utils.dart';
import 'alarm_scheduler.dart';
import 'permissions.dart';
import 'sms_sender.dart';
import 'storage.dart';

/// 闹钟标签常量
class AlarmLabel {
  static const String preClass = '上课提醒';
  static const String postClass = '下课提醒';
  static const String custom = '自定义';
}

class AppState extends ChangeNotifier {
  List<Course> courses = <Course>[];
  List<PeriodTime> periodTimes = <PeriodTime>[];
  List<Alarm> alarms = <Alarm>[];
  List<SmsLog> logs = <SmsLog>[];
  AppSettings settings = const AppSettings();
  int activeWeek = 1;
  bool loaded = false;

  /// 上一次看到的日期，用于判断是否需要重算周次
  DateTime _lastSeenDay = DateTime.now();

  /// 上一次删除的闹钟，用于撤销
  Alarm? lastDeleted;

  final Storage _store = Storage.instance;

  Future<void> init({String? storagePath}) async {
    await _store.init(overridePath: storagePath);
    _pullFromStore();
    settings = await SettingsStore.load();
    loaded = true;
    refreshWeekIfNeeded(force: true);
    notifyListeners();

    // 每次启动都重新注册一遍全部闹钟。
    // 原因：系统闹钟在「强行停止」、重启、更新 App 后会被清空，
    // 这里重注册能自动恢复，用户不需要手动做任何事。
    //
    // 【注意】有课表时必须走 regenerateCourseAlarms 而不是 syncAlarms。
    // syncAlarms 只是把「已经存下来的」闹钟推给系统；如果旧版本存过
    // 错误的配置（例如曾经把 weekdays 写成一周七天，导致周一 08:00 的课
    // 每天 08:00 都响），只 sync 会把错误原样保留下来，
    // 用户必须手动点一次「重新生成提醒」才能修好。
    // 这里直接按当前课表重建，装上新版本就自动生效。
    if (courses.isNotEmpty && periodTimes.isNotEmpty) {
      await regenerateCourseAlarms();
    } else {
      await syncAlarms();
    }
  }

  /// 自动周次：手动指定优先，否则按学期开始日推算
  int? get autoWeek {
    if (settings.usesManualWeek) return settings.weekOverride;
    return weekOfDate(settings.termStart);
  }

  /// 周次是否已经能自动计算（而不是停在默认值）
  bool get weekIsConfigured =>
      settings.usesManualWeek || settings.termStart.isNotEmpty;

  /// 跨天时自动更新当前周次
  ///
  /// 场景：用户在周日晚打开过 App，周一早上再打开（或 App 一直没退出），
  /// 这时应该自动跳到新的一周，而不是等他手动点。
  void refreshWeekIfNeeded({bool force = false}) {
    final DateTime today = DateTime.now();
    final bool dayChanged = today.year != _lastSeenDay.year ||
        today.month != _lastSeenDay.month ||
        today.day != _lastSeenDay.day;
    if (!force && !dayChanged) return;
    _lastSeenDay = today;

    final int? w = autoWeek;
    if (w == null || w < 1) return;
    final int capped = w.clamp(1, settings.totalWeeks);
    if (capped != activeWeek) {
      activeWeek = capped;
      notifyListeners();
    }
  }

  /// 设置学期第一周的周一（设置后周次自动跟随日期变化）
  Future<void> setTermStart(String mondayYmd) async {
    await updateSettings(settings.copyWith(
      termStart: mondayYmd,
      weekOverride: 0, // 一旦设了学期开始日，就回到自动模式
    ));
    refreshWeekIfNeeded(force: true);
  }

  /// 手动指定周次（0 表示回到自动）
  Future<void> setWeekOverride(int week) async {
    await updateSettings(settings.copyWith(weekOverride: week));
    refreshWeekIfNeeded(force: true);
  }

  void _pullFromStore() {
    courses = List<Course>.from(_store.courses);
    periodTimes = List<PeriodTime>.from(_store.periodTimes);
    alarms = List<Alarm>.from(_store.alarms);
    logs = List<SmsLog>.from(_store.logs);
  }

  void _pushToStore() {
    _store.courses = List<Course>.from(courses);
    _store.periodTimes = List<PeriodTime>.from(periodTimes);
    _store.alarms = List<Alarm>.from(alarms);
    _store.logs = List<SmsLog>.from(logs);
    _store.save();
  }

  // ---------------- 课程 ----------------

  Future<void> upsertCourse(Course course) async {
    final int i = courses.indexWhere((Course c) => c.id == course.id);
    if (i >= 0) {
      courses[i] = course;
    } else {
      courses.add(course);
    }
    courses.sort((Course a, Course b) {
      final int w = a.weekday.compareTo(b.weekday);
      return w != 0 ? w : a.startPeriod.compareTo(b.startPeriod);
    });
    _pushToStore();
    notifyListeners();
  }

  Future<void> deleteCourse(String id) async {
    courses.removeWhere((Course c) => c.id == id);
    alarms.removeWhere((Alarm a) => a.courseId == id);
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  /// 批量删除课程（课表页的「批量删除」用）
  Future<int> deleteCourses(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final Set<String> set = ids.toSet();
    final int before = courses.length;
    courses.removeWhere((Course c) => set.contains(c.id));
    // 关联的课表提醒一并删除
    alarms.removeWhere(
        (Alarm a) => a.courseId != null && set.contains(a.courseId!));
    final int removed = before - courses.length;
    _pushToStore();
    notifyListeners();
    await syncAlarms();
    return removed;
  }

  /// 清空全部课程及其关联提醒（识别导入效果不好时用来重来）
  Future<int> clearCourses() async {
    final int removed = courses.length;
    courses = <Course>[];
    alarms.removeWhere((Alarm a) => a.courseId != null);
    _pushToStore();
    notifyListeners();
    await syncAlarms();
    return removed;
  }

  /// 识别导入：写入课程与作息时间
  Future<void> importParsed(ParseResult result, {bool replace = true}) async {
    if (result.periodTimes.isNotEmpty) {
      periodTimes = List<PeriodTime>.from(result.periodTimes);
    }
    if (replace) {
      courses = List<Course>.from(result.courses);
    } else {
      courses.addAll(result.courses);
    }
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  Future<void> setPeriodTimes(List<PeriodTime> list) async {
    periodTimes = List<PeriodTime>.from(list);
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  /// 依据节次取作息时间
  PeriodTime? periodTime(int period) {
    for (final PeriodTime pt in periodTimes) {
      if (pt.period == period) return pt;
    }
    return null;
  }

  // ---------------- 闹钟 ----------------

  /// 由课表重新生成「上课前 N 分钟」「下课前 N 分钟」两类闹钟，
  /// 并保留用户的自定义闹钟。
  ///
  /// 【踩过的大坑】这里曾经把 weekdays 写成
  ///     weekType == 'all' ? [1,2,3,4,5,6,7] : ...
  /// 本意是"每天都可能"，但结果是：周一 08:00 的课变成了**每天 08:00 都响**，
  /// 同一时间的几门课一起轰炸用户。
  ///
  /// 正确做法：**weekdays 永远只放这门课自己的星期**。
  /// 单双周和起止周不是"星期几"的概念，不能用 weekdays 表达，
  /// 必须交给原生侧按"当前是第几周"过滤（见 syncAlarms 里传的周次字段）。
  Future<void> regenerateCourseAlarms() async {
    final List<Alarm> keep =
        alarms.where((Alarm a) => a.courseId == null).toList();

    for (final Course c in courses) {
      final PeriodTime? startPt = periodTime(c.startPeriod);
      final PeriodTime? endPt = periodTime(c.endPeriod);
      if (startPt == null || endPt == null) continue;

      // 只在这一门课自己的星期生效
      final List<int> weekdays = <int>[c.weekday];

      final String place = c.room.isEmpty ? '' : ' ${c.room}';
      final String noteSuffix = c.note.isEmpty ? '' : ' ${c.note}';

      keep.add(Alarm(
        id: 'pre_${c.id}',
        timeMinute: startPt.startMinute - settings.preClassMinutes,
        message: '${c.name}$place$noteSuffix',
        repeatType: 'weekly',
        weekdays: weekdays,
        label: AlarmLabel.preClass,
        courseId: c.id,
        weekday: c.weekday,
      ));

      keep.add(Alarm(
        id: 'post_${c.id}',
        timeMinute: endPt.endMinute - settings.postClassMinutes,
        message: '${c.name}$place 下课了'
            '${c.note.isEmpty ? '' : ' ${c.note}'}',
        repeatType: 'weekly',
        weekdays: weekdays,
        label: AlarmLabel.postClass,
        courseId: c.id,
        weekday: c.weekday,
      ));
    }

    alarms = keep
      ..sort((Alarm a, Alarm b) => a.timeMinute.compareTo(b.timeMinute));
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  Future<void> upsertAlarm(Alarm alarm) async {
    final int i = alarms.indexWhere((Alarm a) => a.id == alarm.id);
    if (i >= 0) {
      alarms[i] = alarm;
    } else {
      alarms.add(alarm);
    }
    alarms.sort((Alarm a, Alarm b) => a.timeMinute.compareTo(b.timeMinute));
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  Future<void> setAlarmEnabled(String id, bool enabled) async {
    final int i = alarms.indexWhere((Alarm a) => a.id == id);
    if (i < 0) return;
    alarms[i] = alarms[i].copyWith(enabled: enabled);
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  Future<void> deleteAlarm(String id) async {
    final int i = alarms.indexWhere((Alarm a) => a.id == id);
    if (i < 0) return;
    lastDeleted = alarms[i];
    alarms.removeAt(i);
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  /// 批量删除闹钟（闹钟页的「批量删除」用）
  ///
  /// 只保留最后一个被删的用于撤销，其余不进撤销栈（避免语义混乱）。
  Future<int> deleteAlarms(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final Set<String> set = ids.toSet();
    final List<Alarm> removed =
        alarms.where((Alarm a) => set.contains(a.id)).toList();
    if (removed.isEmpty) return 0;
    lastDeleted = removed.last;
    alarms.removeWhere((Alarm a) => set.contains(a.id));
    _pushToStore();
    notifyListeners();
    await syncAlarms();
    return removed.length;
  }

  Future<void> undoDelete() async {
    final Alarm? a = lastDeleted;
    if (a == null) return;
    lastDeleted = null;
    await upsertAlarm(a);
  }

  Future<void> clearAlarms() async {
    lastDeleted = null;
    alarms = <Alarm>[];
    _pushToStore();
    notifyListeners();
    await syncAlarms();
  }

  // ---------------- 设置 ----------------

  Future<void> updateSettings(AppSettings value) async {
    settings = value;
    await SettingsStore.save(settings);
    notifyListeners();
    await syncAlarms();
  }

  Future<bool> requestSmsPermission() async {
    if (Platform.isWindows) return false;
    final PermissionStatus status = await Permission.sms.request();
    final bool ok = status.isGranted;
    await updateSettings(settings.copyWith(smsPermissionGranted: ok));
    await AlarmScheduler.requestExactAlarmPermission();
    return ok;
  }

  // ---------------- 权限自检 ----------------

  /// 本次启动是否已经做过权限检查（避免反复提示）
  bool _startupCheckDone = false;

  bool get startupCheckDone => _startupCheckDone;

  void markStartupCheckDone() => _startupCheckDone = true;

  /// 一次性查清各项权限状态
  Future<List<PermissionCheckItem>> permissionChecks() =>
      collectPermissionChecks(settings.smsTo);

  /// 一次性申请短信与通知权限，并尝试跳转精确闹钟设置
  Future<String> requestAllPermissions() async {
    final String summary = await performPermissionRequests(
      onSmsChanged: () async {
        final bool ok = await Permission.sms.isGranted;
        settings = settings.copyWith(smsPermissionGranted: ok);
        await SettingsStore.save(settings);
      },
    );
    notifyListeners();
    return summary;
  }

  /// 打开精确闹钟设置页（跳不过去时原生侧会回退到应用设置页）
  Future<String?> openExactAlarmSettings() =>
      AlarmScheduler.requestExactAlarmPermission();

  // ---------------- 发送（手动触发，同样静默） ----------------

  Future<String> sendNow(Alarm alarm) async {
    final String to = settings.smsTo;
    final bool ok = await SmsSender.send(
      to: to,
      message: alarm.message,
      subscriptionId: settings.smsSubscriptionId,
    );
    final SmsLog log = SmsLog(
      id: 'log_${DateTime.now().microsecondsSinceEpoch}',
      alarmId: alarm.id,
      to: to,
      message: alarm.message,
      sentAt: DateTime.now(),
      result: ok ? 'success' : 'fail',
    );
    logs.insert(0, log);
    _pushToStore();
    notifyListeners();
    return ok ? 'success' : 'fail';
  }

  // ---------------- 调度同步 ----------------

  Future<void> syncAlarms() async {
    if (Platform.isWindows) return;
    final List<Alarm> active = alarms
        .where((Alarm a) => a.enabled && a.message.trim().isNotEmpty)
        .toList();

    // 课表提醒要带上这门课的周次范围，原生侧才能判断"本周有没有这门课"。
    // 否则只在前 8 周上的课会一路响到学期结束。
    final Map<String, Course> byId = <String, Course>{
      for (final Course c in courses) c.id: c,
    };

    final List<Map<String, Object?>> payload = active.map((Alarm a) {
      final Course? c =
          a.courseId == null ? null : byId[a.courseId!];
      return <String, Object?>{
        'id': a.id,
        'timeMinute': a.timeMinute,
        'message': a.message,
        'repeatType': a.repeatType,
        'weekdays': a.weekdays,
        'weekday': a.weekday,
        // 是不是课表闹钟。
        // 自定义闹钟（用户手动建的）跟学期周次无关，原生侧靠这个标记
        // 跳过周次过滤 —— 否则学期过到第 17 周后它们会静默失效。
        'isCourse': c != null,
        'startWeek': c?.startWeek ?? 1,
        'endWeek': c?.endWeek ?? 16,
        'weekType': c?.weekType ?? 'all',
      };
    }).toList();

    await AlarmScheduler.rescheduleAll(
      alarms: payload,
      smsTo: settings.smsTo,
      subscriptionId: settings.smsSubscriptionId,
      mode: settings.reminderMode,
      // 原生侧要靠它算出"今天第几周"
      termStart: settings.termStart,
      weekOverride: settings.weekOverride,
    );
  }

  /// 从系统读一遍 SIM 卡列表（设置页用）
  Future<List<SimCard>> loadSimCards() => SmsSender.listSimCards();

  // ---------------- 界面小状态 ----------------

  /// 切换当前查看的周次
  ///
  /// 只改变显示，不写入设置——用户左右滑动看别的周属于临时操作，
  /// 下次进入 App 或跨天后会自动回到「当前真实周次」。
  void setActiveWeek(int week) {
    if (week < 1) return;
    activeWeek = week;
    notifyListeners();
  }

  /// 回到自动计算的当前周次
  void jumpToCurrentWeek() {
    refreshWeekIfNeeded(force: true);
    final int? w = autoWeek;
    if (w == null) return;
    final int capped = w.clamp(1, settings.totalWeeks);
    if (capped != activeWeek) {
      activeWeek = capped;
      notifyListeners();
    }
  }

  List<Course> coursesOfDay(int weekday) {
    return courses.where((Course c) => c.weekday == weekday).toList();
  }

  List<Alarm> alarmsOfDay(int weekday) {
    return alarms.where((Alarm a) {
      if (a.timeMinute < 0) return false;
      if (a.courseId == null) {
        if (a.repeatType == 'daily') return true;
        if (a.repeatType == 'once') return true;
        return a.weekdays.contains(weekday);
      }
      return a.weekday == weekday;
    }).toList();
  }

  /// 自定义闹钟
  List<Alarm> get customAlarms =>
      alarms.where((Alarm a) => a.courseId == null).toList();

  /// 课表自动闹钟
  List<Alarm> get courseAlarms =>
      alarms.where((Alarm a) => a.courseId != null).toList();

  // ---------------- 导入导出 ----------------

  /// 导出备份文件，返回文件路径
  Future<String> exportToFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path =
        '${dir.path}${Platform.pathSeparator}timetable_backup.json';
    await File(path).writeAsString(_store.exportJson(), flush: true);
    return path;
  }

  /// 从备份文件导入
  Future<void> importFromFile(String path) async {
    final String content = await File(path).readAsString();
    await importFromContent(content);
  }

  /// 直接从备份内容导入（原生文件选择器返回的内容走这里）
  ///
  /// 返回导入了多少门课，便于界面给出反馈。
  /// 兼容两种来源：
  ///   1. App 自己导出的备份（含 courses / periods / alarms）
  ///   2. 电脑端识别工具生成的「课表导入.json」（同一种结构）
  ///
  /// 【注意】识别工具生成的文件里 `alarms` 是空数组。如果直接覆盖，
  /// 用户自己建的闹钟会全部消失。所以这里先留住自定义闹钟
  /// （courseId 为空的就是自定义的），导入后再放回去。
  Future<int> importFromContent(String content) async {
    final List<Alarm> customAlarms =
        alarms.where((Alarm a) => a.courseId == null).toList();

    _store.importJson(content);
    _pullFromStore();

    // 把自定义闹钟找回来（按 id 去重，避免备份里本来就带的话重复）
    final Set<String> ids = alarms.map((Alarm a) => a.id).toSet();
    for (final Alarm a in customAlarms) {
      if (!ids.contains(a.id)) alarms.add(a);
    }

    // 导入课表后，作息时间若齐全就顺手重建上课/下课提醒，
    // 用户不用再手动点一次「重新生成提醒」。
    if (courses.isNotEmpty && periodTimes.isNotEmpty) {
      await regenerateCourseAlarms();
    }
    notifyListeners();
    await syncAlarms();
    return courses.length;
  }
}
