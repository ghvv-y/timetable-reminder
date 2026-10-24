// 无框线课表网格 -> 课程
//
// 输入是原生侧 BorderlessOcr 返回的 JSON：
//   { rows: ["08:00-08:45", ...], days: [1,2,...,7],
//     grid: [ 行 ][ 天 ][ 子槽 ][ 文字行... ], stats: {...} }
//
// 这里负责把「一堆按坐标落好格的文字」变成 Course：
//   · 一格可能有两门课（压缩列）——子槽已分开，各自独立解析
//   · 一门课常跨两个节次行（课名在上、教室在下）——按续行合并
//   · 文字是碎的（「工程图学B」「(1)_03」）——按顺序拼回课名

import 'dart:convert';

import '../model/models.dart';
import '../model/period_time.dart';
import 'paste_parser.dart';

/// 一个子槽解析出的字段
class SlotFields {
  String name = '';
  String teacher = '';
  String room = '';
  List<WeekSpec> weeks = <WeekSpec>[];
  int? startPeriod;
  int? endPeriod;
  final List<String> warnings = <String>[];

  bool get hasName => name.trim().length >= 2;
}

const List<String> _placeHints = <String>[
  '楼', '厅', '场', '馆', '号', '室', '园', '部', '院',
];

final RegExp _rePeriodRange = RegExp(r'(\d{1,2})\s*-\s*(\d{1,2})\s*节');
final RegExp _rePeriodOne = RegExp(r'第?\s*(\d{1,2})\s*节');
final RegExp _reTime = RegExp(
    r'\d{1,2}\s*[:：]\s*\d{2}\s*[-—–~～]\s*\d{1,2}\s*[:：]\s*\d{2}');
final RegExp _reRoomLike = RegExp(r'[A-Za-z]\d{2,}|\d+-\d+');
final RegExp _reCjkTeacher = RegExp(r'^[\u4e00-\u9fa5]{2,4}$');
final RegExp _reHasDigit = RegExp(r'\d');
final RegExp _rePureDigits = RegExp(r'^[\d,\-]+$');

bool _looksLikePlace(String t) {
  if (_placeHints.any(t.contains)) return true;
  if (_reRoomLike.hasMatch(t)) return true;
  return false;
}

/// 解析一个子槽里的文字行，产出字段
SlotFields parseSlotLines(List<String> lines) {
  final SlotFields f = SlotFields();
  final List<String> nameParts = <String>[];
  final List<String> teachers = <String>[];
  final List<String> places = <String>[];

  for (final String raw in lines) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    if (_reTime.hasMatch(t) && t.length <= 20) continue; // 时间栏残留

    // 节次：「3-4节」「第7节」
    final RegExpMatch? pm = _rePeriodRange.firstMatch(t);
    if (pm != null && t.length <= 8) {
      final int a = int.parse(pm.group(1)!);
      final int b = int.parse(pm.group(2)!);
      final int lo = a <= b ? a : b;
      final int hi = a <= b ? b : a;
      f.startPeriod =
          f.startPeriod == null || lo < f.startPeriod! ? lo : f.startPeriod;
      f.endPeriod = f.endPeriod == null || hi > f.endPeriod! ? hi : f.endPeriod;
      continue;
    }
    final RegExpMatch? p1 = _rePeriodOne.firstMatch(t);
    if (p1 != null && t.length <= 6) {
      final int n = int.parse(p1.group(1)!);
      if (n >= 1 && n <= 14) {
        f.startPeriod =
            f.startPeriod == null || n < f.startPeriod! ? n : f.startPeriod;
        f.endPeriod =
            f.endPeriod == null || n > f.endPeriod! ? n : f.endPeriod;
        continue;
      }
    }

    // 周次（含裸数字串，OCR 常把逗号吃掉）
    if (t.contains('周') || _rePureDigits.hasMatch(t)) {
      final List<WeekSpec> w = parseWeekExpr(t, warnings: f.warnings);
      if (w.isNotEmpty) {
        f.weeks.addAll(w);
        continue;
      }
    }

    if (_looksLikePlace(t)) {
      places.add(t);
      continue;
    }

    // 教师：课名已出现之后的 2-4 个汉字（可带星号）
    if (nameParts.isNotEmpty && t.length <= 6) {
      final String core = t.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');
      if (_reCjkTeacher.hasMatch(core) && !_reHasDigit.hasMatch(t)) {
        teachers.add(t);
        continue;
      }
    }
    if (t.contains('*') && t.length <= 14) {
      teachers.add(t);
      continue;
    }

    nameParts.add(t);
  }

  f.name = nameParts.join();
  f.teacher =
      teachers.join(' ').replaceAll(RegExp(r'[^\u4e00-\u9fa5* ]'), '').trim();
  f.room = places.join(' ').trim();
  return f;
}

/// 网格解析结果
class GridParseResult {
  final List<Course> courses;
  final List<PeriodTime> periods;
  final List<String> warnings;
  final String stats;

  const GridParseResult({
    required this.courses,
    required this.periods,
    this.warnings = const <String>[],
    this.stats = '',
  });

  bool get isEmpty => courses.isEmpty && periods.isEmpty;
}

int? _labelToMinutes(String s, {required bool start}) {
  final RegExpMatch? m = RegExp(
          r'(\d{1,2})\s*[:：]\s*(\d{2})\s*[-—–~～]\s*(\d{1,2})\s*[:：]\s*(\d{2})')
      .firstMatch(s);
  if (m == null) return null;
  return start
      ? int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)
      : int.parse(m.group(3)!) * 60 + int.parse(m.group(4)!);
}

/// 构造中的课程（可变，便于续行补充）
class _Building {
  int weekday = 1;
  String name = '';
  String teacher = '';
  String room = '';
  List<WeekSpec> weeks = <WeekSpec>[];
  int startPeriod = 1;
  int endPeriod = 1;
  final List<String> warnings = <String>[];
}

/// 解析原生侧返回的网格 JSON
GridParseResult parseGridJson(String json) {
  final Map<String, Object?> root =
      Map<String, Object?>.from(jsonDecode(json) as Map);

  final List<String> rows =
      ((root['rows'] as List<Object?>?) ?? <Object?>[])
          .map((Object? e) => '$e')
          .toList();
  final List<int> days = ((root['days'] as List<Object?>?) ?? <Object?>[])
      .map((Object? e) => (e as num).toInt())
      .toList();
  final List<Object?> gridRaw = (root['grid'] as List<Object?>?) ?? <Object?>[];

  final List<PeriodTime> periods = <PeriodTime>[];
  for (final String label in rows) {
    final int? s = _labelToMinutes(label, start: true);
    final int? e = _labelToMinutes(label, start: false);
    if (s == null || e == null || e <= s) continue;
    periods.add(PeriodTime(
      period: periods.length + 1,
      startMinute: s,
      endMinute: e,
    ));
  }

  final List<_Building> buildings = <_Building>[];

  // 逐列处理：续行只会在同一列内出现
  for (int ci = 0; ci < days.length; ci++) {
    final int weekday = days[ci];

    // 【踩过的坑】续行的「上一门课」必须**按子槽分别跟踪**。
    // 早先用单个 cur 变量，压缩列（同一天两门课并排）会串行：
    // 周一的 A204（形势与政策）被并进了专业导论。
    final List<_Building?> curBySlot = <_Building?>[null, null];

    for (int ri = 0; ri < gridRaw.length; ri++) {
      final List<Object?> row = (gridRaw[ri] as List<Object?>?) ?? <Object?>[];
      if (ci >= row.length) continue;
      final List<Object?> cell = (row[ci] as List<Object?>?) ?? <Object?>[];

      for (int slot = 0; slot < cell.length && slot < 2; slot++) {
        final List<String> lines = ((cell[slot] as List<Object?>?) ?? <Object?>[])
            .map((Object? e) => '$e')
            .toList();
        if (lines.isEmpty) continue;

        final SlotFields f = parseSlotLines(lines);
        final int rowPeriod = ri + 1;

        if (f.hasName) {
          final _Building b = _Building()
            ..weekday = weekday
            ..name = f.name
            ..teacher = f.teacher
            ..room = f.room
            ..weeks = List<WeekSpec>.from(f.weeks)
            ..startPeriod = f.startPeriod ?? rowPeriod
            ..endPeriod = f.endPeriod ?? f.startPeriod ?? rowPeriod;
          b.warnings.addAll(f.warnings);
          buildings.add(b);
          curBySlot[slot] = b;
        } else if (curBySlot[slot] != null) {
          final _Building cur = curBySlot[slot]!;
          if (cur.room.isEmpty && f.room.isNotEmpty) cur.room = f.room;
          if (cur.weeks.isEmpty && f.weeks.isNotEmpty) {
            cur.weeks = List<WeekSpec>.from(f.weeks);
          }
          if (f.startPeriod != null) {
            final int a = f.startPeriod!;
            final int b = f.endPeriod ?? a;
            if (a < cur.startPeriod) cur.startPeriod = a;
            if (b > cur.endPeriod) cur.endPeriod = b;
          }
          cur.warnings.addAll(f.warnings);
        }
      }
    }
  }

  final List<Course> out = <Course>[];
  final List<String> warnings = <String>[];
  int seq = 0;

  for (final _Building b in buildings) {
    warnings.addAll(b.warnings);
    if (b.name.trim().length < 2) continue;
    final List<WeekSpec> use = b.weeks.isEmpty
        ? <WeekSpec>[const WeekSpec(1, 16, 'all')]
        : b.weeks;
    for (final WeekSpec w in use) {
      out.add(Course(
        id: 'grid_${seq++}',
        name: b.name.trim(),
        weekday: b.weekday,
        startPeriod: b.startPeriod <= b.endPeriod
            ? b.startPeriod
            : b.endPeriod,
        endPeriod: b.startPeriod <= b.endPeriod ? b.endPeriod : b.startPeriod,
        room: b.room.trim(),
        teacher: b.teacher.trim(),
        startWeek: w.startWeek,
        endWeek: w.endWeek,
        weekType: w.weekType,
      ));
    }
  }

  out.sort((Course a, Course b) {
    final int w = a.weekday.compareTo(b.weekday);
    return w != 0 ? w : a.startPeriod.compareTo(b.startPeriod);
  });

  final Object? stats = root['stats'];
  return GridParseResult(
    courses: out,
    periods: periods,
    warnings: warnings.toSet().toList(),
    stats: stats == null ? '' : jsonEncode(stats),
  );
}
