// 数据模型：课程 / 闹钟 / 短信日志 / 应用设置
//
// 核心规则（不可违背）：
// 1. 闹钟的 message 字段就是短信正文，原样发送，程序不追加、不改写。
// 2. 闹钟到点完全静默：不响铃、不震动、不弹通知。
//
// 作息时间模型单独放在 period_time.dart，便于解析模块与测试复用。

/// 一节课
class Course {
  /// 唯一主键
  final String id;

  /// 课程名
  final String name;

  /// 星期：1=周一 ... 7=周日
  final int weekday;

  /// 起始节次（第几节，从 1 开始）
  final int startPeriod;

  /// 结束节次（含）
  final int endPeriod;

  /// 地点
  final String room;

  /// 教师
  final String teacher;

  /// 起止周：1 - 16
  final int startWeek;
  final int endWeek;

  /// 周次类型：all 每周 / odd 单周 / even 双周
  final String weekType;

  /// 备注（可被闹钟引用）
  final String note;

  const Course({
    required this.id,
    required this.name,
    required this.weekday,
    required this.startPeriod,
    required this.endPeriod,
    this.room = '',
    this.teacher = '',
    this.startWeek = 1,
    this.endWeek = 16,
    this.weekType = 'all',
    this.note = '',
  });

  Course copyWith({
    // id 也允许改：导入时若 id 为空或重复，需要重新分配一个唯一 id。
    // 不分配的话所有课程的闹钟 id 会撞成同一个（pre_ / post_），
    // 结果只剩最后一条提醒生效。
    String? id,
    String? name,
    int? weekday,
    int? startPeriod,
    int? endPeriod,
    String? room,
    String? teacher,
    int? startWeek,
    int? endWeek,
    String? weekType,
    String? note,
  }) {
    return Course(
      id: id ?? this.id,
      name: name ?? this.name,
      weekday: weekday ?? this.weekday,
      startPeriod: startPeriod ?? this.startPeriod,
      endPeriod: endPeriod ?? this.endPeriod,
      room: room ?? this.room,
      teacher: teacher ?? this.teacher,
      startWeek: startWeek ?? this.startWeek,
      endWeek: endWeek ?? this.endWeek,
      weekType: weekType ?? this.weekType,
      note: note ?? this.note,
    );
  }

  bool get isSingleWeek => weekType == 'odd';
  bool get isDoubleWeek => weekType == 'even';

  /// 该课程在第 week 周是否上课
  bool occursInWeek(int week) {
    if (week < startWeek || week > endWeek) return false;
    if (weekType == 'odd') return week.isOdd;
    if (weekType == 'even') return week.isEven;
    return true;
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'weekday': weekday,
        'startPeriod': startPeriod,
        'endPeriod': endPeriod,
        'room': room,
        'teacher': teacher,
        'startWeek': startWeek,
        'endWeek': endWeek,
        'weekType': weekType,
        'note': note,
      };

  factory Course.fromMap(Map<String, Object?> m) => Course(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        weekday: int.tryParse('${m['weekday']}') ?? 1,
        startPeriod: int.tryParse('${m['startPeriod']}') ?? 1,
        endPeriod: int.tryParse('${m['endPeriod']}') ?? 1,
        room: (m['room'] ?? '').toString(),
        teacher: (m['teacher'] ?? '').toString(),
        startWeek: int.tryParse('${m['startWeek']}') ?? 1,
        endWeek: int.tryParse('${m['endWeek']}') ?? 16,
        weekType: (m['weekType'] ?? 'all').toString(),
        note: (m['note'] ?? '').toString(),
      );
}

/// 闹钟：一条「到点静默发出短信」的计划
///
/// 关键点：
/// - [message] 就是短信正文（也就是备注），原样发送。
/// - 到点时不响铃、不震动、不弹通知，唯一动作是发送短信。
/// - [courseId] 非空表示由课表自动生成（上课/下课提醒），为空表示用户自定义闹钟。
class Alarm {
  final String id;

  /// 发送时刻（当天分钟数，例如 09:45 = 585）
  final int timeMinute;

  /// 备注 = 短信正文，原样发送
  final String message;

  /// once 仅一次 / daily 每天 / weekly 按星期
  final String repeatType;

  /// repeatType == weekly 时生效，1=周一 ... 7=周日
  final List<int> weekdays;

  final bool enabled;

  /// 展示用标签：上课提醒 / 下课提醒 / 自定义
  final String label;

  /// 关联课程（课表自动闹钟）
  final String? courseId;

  /// 生成的闹钟对应的星期（once / weekly 时用于调度）
  final int? weekday;

  const Alarm({
    required this.id,
    required this.timeMinute,
    required this.message,
    this.repeatType = 'once',
    this.weekdays = const <int>[],
    this.enabled = true,
    this.label = '自定义',
    this.courseId,
    this.weekday,
  });

  Alarm copyWith({
    int? timeMinute,
    String? message,
    String? repeatType,
    List<int>? weekdays,
    bool? enabled,
    String? label,
    String? courseId,
    int? weekday,
  }) {
    return Alarm(
      id: id,
      timeMinute: timeMinute ?? this.timeMinute,
      message: message ?? this.message,
      repeatType: repeatType ?? this.repeatType,
      weekdays: weekdays ?? this.weekdays,
      enabled: enabled ?? this.enabled,
      label: label ?? this.label,
      courseId: courseId ?? this.courseId,
      weekday: weekday ?? this.weekday,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'timeMinute': timeMinute,
        'message': message,
        'repeatType': repeatType,
        'weekdays': weekdays.join(','),
        'enabled': enabled ? 1 : 0,
        'label': label,
        'courseId': courseId,
        'weekday': weekday,
      };

  factory Alarm.fromMap(Map<String, Object?> m) => Alarm(
        id: (m['id'] ?? '').toString(),
        timeMinute: int.tryParse('${m['timeMinute']}') ?? 0,
        message: (m['message'] ?? '').toString(),
        repeatType: (m['repeatType'] ?? 'once').toString(),
        weekdays: _parseWeekdays(m['weekdays']),
        enabled: '${m['enabled']}' == '1' || '${m['enabled']}' == 'true',
        label: (m['label'] ?? '自定义').toString(),
        courseId: (m['courseId'] == null || '${m['courseId']}' == '')
            ? null
            : '${m['courseId']}',
        weekday: (m['weekday'] == null || '${m['weekday']}' == '')
            ? null
            : int.tryParse('${m['weekday']}'),
      );

  /// 兼容三种写法：
  ///   "1,3,5"        （本 App 存档格式）
  ///   [1, 3, 5]      （手写 JSON 常见的数组写法）
  ///   1              （单个数字，顺手容错）
  /// 只在 1..7 范围内保留，越界值丢弃（原生侧 nextTrigger 也只在 1..7 里找）。
  static List<int> _parseWeekdays(Object? value) {
    if (value == null) return const <int>[];
    final List<int> out = <int>[];
    if (value is List) {
      for (final Object? e in value) {
        final int? n = int.tryParse('$e');
        if (n != null && n >= 1 && n <= 7) out.add(n);
      }
      return out;
    }
    final String s = value.toString();
    for (final String part in s.split(',')) {
      final int? n = int.tryParse(part.trim());
      if (n != null && n >= 1 && n <= 7) out.add(n);
    }
    return out;
  }
}

/// 短信发送日志：静默记录，便于核对是否漏发
class SmsLog {
  final String id;
  final String alarmId;
  final String to;
  final String message;
  final DateTime sentAt;

  /// success / fail
  final String result;

  const SmsLog({
    required this.id,
    required this.alarmId,
    required this.to,
    required this.message,
    required this.sentAt,
    required this.result,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'alarmId': alarmId,
        'to': to,
        'message': message,
        'sentAt': sentAt.millisecondsSinceEpoch,
        'result': result,
      };

  factory SmsLog.fromMap(Map<String, Object?> m) => SmsLog(
        id: (m['id'] ?? '').toString(),
        alarmId: (m['alarmId'] ?? '').toString(),
        to: (m['to'] ?? '').toString(),
        message: (m['message'] ?? '').toString(),
        sentAt: DateTime.fromMillisecondsSinceEpoch(
            int.tryParse('${m['sentAt']}') ?? 0),
        result: (m['result'] ?? 'success').toString(),
      );
}

/// 一张 SIM 卡
class SimCard {
  /// 系统分配的订阅 id（发短信时指定它，就不会弹选卡框）
  final int subscriptionId;

  /// 卡槽序号（0 或 1）
  final int slotIndex;

  /// 显示名，例如「卡1 · 中国移动」
  final String label;

  /// 号码（多数机型取不到，可能为空）
  final String number;

  const SimCard({
    required this.subscriptionId,
    required this.slotIndex,
    required this.label,
    this.number = '',
  });

  static SimCard? fromMap(Map<String, Object?> m) {
    final int id = int.tryParse('${m['subscriptionId']}') ?? -1;
    if (id < 0) return null;
    return SimCard(
      subscriptionId: id,
      slotIndex: int.tryParse('${m['slotIndex']}') ?? 0,
      label: (m['label'] ?? '').toString(),
      number: (m['number'] ?? '').toString(),
    );
  }

  /// 供界面显示
  String get display =>
      number.isEmpty ? label : '$label（$number）';
}

/// 应用设置
class AppSettings {
  /// 短信接收号码（通常为本机号码，短信兜回手机后同步到手表）
  final String smsTo;

  /// 指定用哪张卡发送（-1 表示未指定，交给系统决定/让用户选）
  final int smsSubscriptionId;

  /// 短信开关
  final bool smsEnabled;

  /// 提醒方式：both=通知+短信，notify=仅通知，sms=仅短信
  ///
  /// 为什么要有「仅通知」：
  ///   手表不认短信，只认通知。而自己发给自己的短信，系统短信应用会当成
  ///   自己的对话线程，不打红点也不弹通知 —— 单卡手机就彻底收不到提醒。
  ///   改成由本应用直接弹一条静默通知，就绕开了运营商、短信应用，
  ///   以及厂商的「后台发短信」限制。
  final String reminderMode;

  /// 静默模式：固定为 true，到点不响铃不震动不弹窗
  final bool silentMode;

  /// 上课提醒提前量（分钟）
  final int preClassMinutes;

  /// 下课提醒提前量（分钟）
  final int postClassMinutes;

  /// 学期第一周的周一（yyyy-MM-dd）。设置后周次会自动跟随日期变化。
  final String termStart;

  /// 手动指定的周次（0 表示自动计算）。
  /// 用于学期开始日没配对、或临时想查看别的周次。
  final int weekOverride;

  /// 一学期总周数（用于进度条与边界判断）
  final int totalWeeks;

  /// 是否已授予发送短信权限
  final bool smsPermissionGranted;

  const AppSettings({
    this.smsTo = '',
    this.smsSubscriptionId = -1,
    this.smsEnabled = true,
    this.reminderMode = 'both',
    this.silentMode = true,
    this.preClassMinutes = 5,
    this.postClassMinutes = 5,
    this.termStart = '',
    this.weekOverride = 0,
    this.totalWeeks = 16,
    this.smsPermissionGranted = false,
  });

  AppSettings copyWith({
    String? smsTo,
    int? smsSubscriptionId,
    bool? smsEnabled,
    String? reminderMode,
    bool? silentMode,
    int? preClassMinutes,
    int? postClassMinutes,
    String? termStart,
    int? weekOverride,
    int? totalWeeks,
    bool? smsPermissionGranted,
  }) {
    return AppSettings(
      smsTo: smsTo ?? this.smsTo,
      smsSubscriptionId: smsSubscriptionId ?? this.smsSubscriptionId,
      smsEnabled: smsEnabled ?? this.smsEnabled,
      reminderMode: reminderMode ?? this.reminderMode,
      silentMode: silentMode ?? this.silentMode,
      preClassMinutes: preClassMinutes ?? this.preClassMinutes,
      postClassMinutes: postClassMinutes ?? this.postClassMinutes,
      termStart: termStart ?? this.termStart,
      weekOverride: weekOverride ?? this.weekOverride,
      totalWeeks: totalWeeks ?? this.totalWeeks,
      smsPermissionGranted: smsPermissionGranted ?? this.smsPermissionGranted,
    );
  }

  /// 是否处于手动指定周次模式
  bool get usesManualWeek => weekOverride > 0;

  Map<String, Object?> toJson() => {
        'smsTo': smsTo,
        'smsSubscriptionId': smsSubscriptionId,
        'smsEnabled': smsEnabled,
        'reminderMode': reminderMode,
        'silentMode': silentMode,
        'preClassMinutes': preClassMinutes,
        'postClassMinutes': postClassMinutes,
        'termStart': termStart,
        'weekOverride': weekOverride,
        'totalWeeks': totalWeeks,
        'smsPermissionGranted': smsPermissionGranted,
      };

  factory AppSettings.fromJson(Map<String, Object?> m) => AppSettings(
        smsTo: (m['smsTo'] ?? '').toString(),
        smsSubscriptionId: int.tryParse('${m['smsSubscriptionId']}') ?? -1,
        smsEnabled: m['smsEnabled'] != false,
        reminderMode: (m['reminderMode'] ?? 'both').toString(),
        silentMode: m['silentMode'] != false,
        preClassMinutes: int.tryParse('${m['preClassMinutes']}') ?? 5,
        postClassMinutes: int.tryParse('${m['postClassMinutes']}') ?? 5,
        termStart: (m['termStart'] ?? '').toString(),
        weekOverride: int.tryParse('${m['weekOverride']}') ?? 0,
        totalWeeks: int.tryParse('${m['totalWeeks']}') ?? 16,
        smsPermissionGranted: m['smsPermissionGranted'] == true,
      );
}
