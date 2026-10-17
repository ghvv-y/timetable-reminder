// 时间工具：分钟数与时钟文本互转、星期文本、周次计算

/// 585 -> "09:45"
String fmtMinute(int minute) {
  final int m = minute % (24 * 60);
  final int h = m ~/ 60;
  final int mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

/// "09:45" / "9：45" -> 585，解析失败返回 null
int? parseMinute(String text) {
  final String normalized = text
      .replaceAll('：', ':')
      .replaceAll('．', '.')
      .replaceAll('.', ':')
      .trim();
  final RegExp re = RegExp(r'^(\d{1,2}):?(\d{2})?$');
  final Match? m = re.firstMatch(normalized);
  if (m == null) return null;
  final int h = int.parse(m.group(1)!);
  final int mm = int.parse(m.group(2) ?? '0');
  if (h > 23 || mm > 59) return null;
  return h * 60 + mm;
}

/// "08:00 - 08:45" -> [480, 525]
List<int>? parseRange(String text) {
  final List<String> parts =
      text.replaceAll('：', ':').split(RegExp(r'[-—~至]|\s{2,}'));
  if (parts.length < 2) return null;
  final int? a = parseMinute(parts[0]);
  final int? b = parseMinute(parts[1]);
  if (a == null || b == null) return null;
  return <int>[a, b];
}

const List<String> weekdayNames = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

String weekdayName(int weekday) {
  if (weekday < 1 || weekday > 7) return '';
  return weekdayNames[weekday - 1];
}

/// 日期 -> "2026-09-01"
String fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 取某一天所在周的周一（以周一为一周之首）
DateTime mondayOf(DateTime d) {
  final DateTime day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// 计算「某一天处于学期的第几周」
///
/// [termStartMonday] 是学期第 1 周的周一（yyyy-MM-dd）。
/// 返回 null 表示还没设置学期开始日，无法判断。
///
/// 注意：开学前的日期返回 1（而不是 0 或负数），
/// 否则界面上会出现「第 -2 周」，课时筛选也会错乱。
int? weekOfDate(String termStartMonday, {DateTime? now}) {
  if (termStartMonday.isEmpty) return null;
  final DateTime? start = DateTime.tryParse(termStartMonday);
  if (start == null) return null;

  final DateTime startMonday = mondayOf(start);
  final DateTime today = now ?? DateTime.now();
  final int diffDays = mondayOf(today).difference(startMonday).inDays;
  final int week = diffDays ~/ 7 + 1;
  return week < 1 ? 1 : week;
}

/// 兼容旧调用：算不出来时退回第 1 周
int currentWeek(String termStart, {DateTime? now}) =>
    weekOfDate(termStart, now: now) ?? 1;

/// 学期第 1 周周一到指定周次周一的日期
DateTime mondayOfWeek(String termStartMonday, int week) {
  final DateTime? start = DateTime.tryParse(termStartMonday);
  final DateTime base = start == null
      ? mondayOf(DateTime.now())
      : mondayOf(start);
  return base.add(Duration(days: (week - 1) * 7));
}

/// 当前周次的日期区间文本，例如 "09-01 ~ 09-07"
String weekRangeText(String termStartMonday, int week) {
  final DateTime mon = mondayOfWeek(termStartMonday, week);
  final DateTime sun = mon.add(const Duration(days: 6));
  String md(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return '${md(mon)} ~ ${md(sun)}';
}
