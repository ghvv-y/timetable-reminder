// 课表格子 -> 课程 / 作息时间
//
// 移植自桌面端 tools/recognize_schedule.py 的
//   parse_times / looks_like_place / parse_cell / split_paired_cell / build_courses
//
// 为什么要在 Dart 里再做一遍解析：
//   Kotlin 侧只负责「把图切格 + 逐格 OCR」，返回的是
//   (行, 列) -> [文字行...]。至于哪一格是时间栏、哪一格是课名、
//   怎么把多行拼成一门课，全部沿用桌面端已经验证过的规则，
//   保证手机端和电脑端识别结果一致。
//
// 纯函数、无副作用、不依赖平台，可直接单元测试。

import '../model/models.dart';
import '../model/period_time.dart';

/// 一个格子的原始内容
class OcrCell {
  final int row;
  final int col;
  final List<String> lines;

  const OcrCell({required this.row, required this.col, required this.lines});
}

/// 解析结果
class CellParseResult {
  final List<Course> courses;
  final List<PeriodTime> periods;

  /// 解析失败的格子说明（给界面提示用）
  final List<String> warnings;

  /// 原始格子文字（界面上展开核对用，不必再跑一次识别）
  final List<OcrCell> cells;

  const CellParseResult({
    required this.courses,
    required this.periods,
    this.warnings = const <String>[],
    this.cells = const <OcrCell>[],
  });
}

// ---------------- 可调配置 ----------------
//
// 与桌面端 PLACE_WORDS / PLACE_PREFIXES 保持一致。
// 换学校时改这里即可。

/// 「地点」关键词：出现这些字就认为不是课名
const List<String> placeWords = <String>[
  '楼', '馆', '厅', '室', '操场', '报告', '园', '号',
];

/// 地点常见前缀（校区名）
const List<String> placePrefixes = <String>[
  '校本部', '本部', '北校', '南校', '东校', '西校', '学校',
];

/// 噪声词（表头、统计行等，不是课程内容）
const Set<String> noiseWords = <String>{
  '上午', '下午', '晚上', '学分', '课程属性', '课程类别', '考试类型',
  '修读方式', '选课状态', '选课限制说明', '教师', '地点', '时间',
  '课序号', '课程号', '课程名', '必修', '选修', '考查', '考试',
  '节次/时间', '未安排时间/地点课程清单',
};

// ---------------- 正则 ----------------

/// 时间区间：08:00-08:45（也认中文冒号和各种破折号）
final RegExp reTimeRange = RegExp(
    r'(\d{1,2})\s*[:：]\s*(\d{2})\s*[-—–~～至到]\s*(\d{1,2})\s*[:：]\s*(\d{2})');

/// 节次区间：1-2节
final RegExp rePeriodRange = RegExp(r'(\d{1,2})\s*[-—–~～至]\s*(\d{1,2})\s*节');

/// 单个节次：第3节 / 3节
final RegExp rePeriodOne = RegExp(r'(\d{1,2})\s*节');

/// 周次区间：3-16周
final RegExp reWeekRange = RegExp(r'(\d{1,2})\s*[-—–~～至]\s*(\d{1,2})\s*周');

/// 单个周次：第7周 / 7周
final RegExp reWeekOne = RegExp(r'第?\s*(\d{1,2})\s*周');

/// 带星号/符号的教师名：李帅* / 艾娟＊
final RegExp reTeacherStar =
    RegExp(r'^[\u4e00-\u9fa5]{1,4}\s*[＊*·。、,"”]+$');

/// 房间号：A202 / 3-310
final RegExp reRoom = RegExp(r'[A-Za-z]\d{1,3}\s*[-—]\s*\d{1,3}');

final RegExp _reHasCjk = RegExp(r'[\u4e00-\u9fa5]');
final RegExp _rePureDigits = RegExp(r'^\d{1,3}$');
final RegExp _reLetterRoom = RegExp(r'^[A-Za-z]\d{1,4}([-—]\d{1,4})?$');
final RegExp _reDashRoom = RegExp(r'^\d{1,4}[-—]\d{1,4}$');
final RegExp _reTeacherName = RegExp(r'^[\u4e00-\u9fa5]{2,3}$');
final RegExp _reHasAlnum = RegExp(r'[A-Za-z0-9]');

// ---------------- 时间栏 ----------------

/// 从最左列（col == 0）解析作息时间。
///
/// [cells] 是全表格子；只有 col == 0 的参与。
List<PeriodTime> parseTimes(List<OcrCell> cells) {
  final Map<int, OcrCell> byRow = <int, OcrCell>{};
  for (final OcrCell c in cells) {
    if (c.col == 0) byRow[c.row] = c;
  }
  final List<int> rows = byRow.keys.toList()..sort();

  final List<PeriodTime> out = <PeriodTime>[];
  for (final int r in rows) {
    for (final String t in byRow[r]!.lines) {
      final Match? m = reTimeRange.firstMatch(t);
      if (m == null) continue;
      final int start = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
      final int end = int.parse(m.group(3)!) * 60 + int.parse(m.group(4)!);
      if (start < 0 || start > 1439 || end <= start) continue;
      out.add(PeriodTime(
        period: out.length + 1,
        startMinute: start,
        endMinute: end,
      ));
      break; // 一个格子只算一节
    }
  }
  return out;
}

// ---------------- 地点 / 格子解析 ----------------

/// 判断文字是否像「地点」而不是课名
bool looksLikePlace(String t) {
  for (final String pre in placePrefixes) {
    if (t.startsWith(pre)) return true;
  }
  for (final String k in placeWords) {
    if (t.contains(k)) return true;
  }
  if (reRoom.hasMatch(t)) return true;
  // 房间号：必须带字母或带横杠，否则纯数字（课程编号 29 / 01）会误判
  final String s = t.replaceAll(' ', '');
  if (_reLetterRoom.hasMatch(s)) return true;
  if (_reDashRoom.hasMatch(s)) return true;
  return false;
}

/// 一个格子解析出来的字段
class ParsedCell {
  String name = '';
  String teacher = '';
  String room = '';
  int startWeek = 1;
  int endWeek = 16;
  int? startPeriod;
  int? endPeriod;

  bool get hasName => name.isNotEmpty;

  @override
  String toString() =>
      'name=$name teacher=$teacher room=$room '
      'period=$startPeriod-$endPeriod week=$startWeek-$endWeek';
}

/// 解析一个格子的文字行
ParsedCell? parseCell(List<String> lines, int periodHint) {
  final ParsedCell out = ParsedCell();
  final List<String> nameLines = <String>[];
  bool nameClosed = false;
  String teacher = '';
  String room = '';
  int sw = 1;
  int ew = 16;
  int? sp;
  int? ep;

  for (final String raw in lines) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    if (noiseWords.contains(t)) continue;
    if (t == '__supp__') continue;

    // 节次区间
    Match? m = rePeriodRange.firstMatch(t);
    if (m != null) {
      final int a = int.parse(m.group(1)!);
      final int b = int.parse(m.group(2)!);
      sp = a < b ? a : b;
      ep = a < b ? b : a;
      continue;
    }

    // 周次区间
    m = reWeekRange.firstMatch(t);
    if (m != null) {
      final int a = int.parse(m.group(1)!);
      final int b = int.parse(m.group(2)!);
      sw = a < b ? a : b;
      ew = a < b ? b : a;
      continue;
    }

    // 单个周次（「第7周」这种）
    m = reWeekOne.firstMatch(t);
    if (m != null && !t.contains('节') && t.length <= 6) {
      final int n = int.parse(m.group(1)!);
      if (n >= 1 && n <= 30) {
        sw = n;
        ew = n;
      }
      continue;
    }

    // 单个节次
    m = rePeriodOne.firstMatch(t);
    if (m != null && t.length <= 6 && sp == null) {
      final int n = int.parse(m.group(1)!);
      if (n >= 1 && n <= 12) {
        sp = n;
        ep = n;
      }
      continue;
    }

    // 地点要先于课名判定（教室写在下一行，不能当课名）
    if (looksLikePlace(t)) {
      room = room.isEmpty ? t : '$room $t';
      continue;
    }

    // 纯数字是课程编号的后半段，不是地点
    if (_rePureDigits.hasMatch(t)) {
      nameLines.add(t);
      continue;
    }

    // 教师行：带星号的，或「已收集到课名」后的 2-3 个汉字。
    // 后者必须要求已有课名，否则「体育」这种两字课名会被误判成人名。
    if (reTeacherStar.hasMatch(t) || (nameLines.isNotEmpty && _reTeacherName.hasMatch(t))) {
      if (teacher.isEmpty) teacher = t;
      nameClosed = true;
      continue;
    }

    // 课名可能连续多行（工程图学B / （1） / _03）
    if (!nameClosed && (_reHasCjk.hasMatch(t) || _reHasAlnum.hasMatch(t))) {
      nameLines.add(t);
    }
  }

  final String name = nameLines.join();
  // 只有地点/教师、没有课名也算有效（用作续行补充）
  if ((name.isEmpty || name.length < 2) && room.isEmpty && teacher.isEmpty) {
    return null;
  }

  out.name = name;
  out.teacher = teacher;
  out.room = room;
  out.startWeek = sw;
  out.endWeek = ew;
  out.startPeriod = sp ?? periodHint;
  out.endPeriod = ep ?? periodHint;
  return out;
}

/// 把「一个格子装了两门课」拆开（下午列宽只有一半时会出现）
///
/// 判据：格子里出现 ≥2 个周次范围 或 ≥2 个节次范围。
/// 返回 [(文字行, 星期偏移)]；偏移 0 表示本列，1 表示下一列。
List<({List<String> lines, int offset})> splitPairedCell(List<String> texts) {
  if (texts.length < 4) {
    return <({List<String> lines, int offset})>[(lines: texts, offset: 0)];
  }
  int weeks = 0;
  int periods = 0;
  for (final String t in texts) {
    if (reWeekRange.hasMatch(t) || reWeekOne.hasMatch(t)) weeks++;
    if (rePeriodRange.hasMatch(t)) periods++;
  }
  if (weeks < 2 && periods < 2) {
    return <({List<String> lines, int offset})>[(lines: texts, offset: 0)];
  }
  if (texts.length % 2 != 0) {
    return <({List<String> lines, int offset})>[(lines: texts, offset: 0)];
  }
  final List<String> even = <String>[];
  final List<String> odd = <String>[];
  for (int i = 0; i < texts.length; i++) {
    if (i.isEven) {
      even.add(texts[i]);
    } else {
      odd.add(texts[i]);
    }
  }
  return <({List<String> lines, int offset})>[
    (lines: even, offset: 0),
    (lines: odd, offset: 1),
  ];
}

// ---------------- 课程组装 ----------------

/// 可变的课程构造过程（解析期间用）
class _Building {
  String name = '';
  String teacher = '';
  String room = '';
  int weekday = 1;
  int startPeriod = 1;
  int endPeriod = 1;
  int startWeek = 1;
  int endWeek = 16;
  bool explicitPeriod = false;

  bool defaultWeeks() => startWeek == 1 && endWeek == 16;
}

/// 把格子转成课程 + 作息时间。
///
/// 关键规则（与桌面端一致）：
///   - 一门课常跨多个格子行：课名在第 1 行、教室在第 2 行 → 必须合并
///   - 同名且节次紧邻才合并；否则另起一门（周五 1-2 和 5-6 都叫高等数学，是两门）
///   - 一格两门课按奇偶位拆开，第二门属于「下一列」
CellParseResult parseSchedule(List<OcrCell> cells) {
  final List<PeriodTime> periods = parseTimes(cells);
  final List<String> warnings = <String>[];

  if (periods.isEmpty) {
    return CellParseResult(
      courses: <Course>[],
      periods: periods,
      warnings: <String>['没识别出作息时间（左侧时间栏为空或格式不认识）'],
      cells: cells,
    );
  }

  // 行号 -> 节次
  final Map<int, int> row2period = <int, int>{};
  final List<int> timeRows = <int>[];
  for (final OcrCell c in cells) {
    if (c.col != 0) continue;
    for (final String t in c.lines) {
      if (reTimeRange.hasMatch(t)) {
        timeRows.add(c.row);
        break;
      }
    }
  }
  timeRows.sort();
  for (int i = 0; i < timeRows.length && i < periods.length; i++) {
    row2period[timeRows[i]] = periods[i].period;
  }

  final int maxCol = cells.isEmpty
      ? 0
      : cells.map((OcrCell c) => c.col).reduce((int a, int b) => a > b ? a : b);

  final List<Course> result = <Course>[];
  // 先收集「可变的构建中对象」，最后一并转成不可变的 Course。
  // 【踩过的坑】早先在这里直接 result.add(_toCourse(b)) 生成了快照，
  // 后续再往 b 里补教室/教师（跨格子续行的正常流程）就全都丢了 ——
  // 表现为「课名对了但没有教室」。
  final List<_Building> builders = <_Building>[];
  int seq = 0;

  for (int col = 1; col <= maxCol; col++) {
    final List<OcrCell> colCells =
        cells.where((OcrCell c) => c.col == col).toList()
          ..sort((OcrCell a, OcrCell b) => a.row.compareTo(b.row));
    _Building? current;

    for (final OcrCell cell in colCells) {
      final int? period = row2period[cell.row];
      if (period == null) continue;

      // 一格可能装两门课
      final parts = splitPairedCell(cell.lines);
      final bool compressed = parts.length > 1;

      for (final ({List<String> lines, int offset}) part in parts) {
        // 压缩行的星期公式：2×列号-1+偏移，必须夹在 1..7
        int wd = compressed ? (2 * col - 1 + part.offset) : col;
        if (wd < 1) wd = 1;
        if (wd > 7) wd = 7;

        final ParsedCell? info = parseCell(part.lines, period);

        // 无课名 = 本门课的续行（只有教室/教师），并入上一门
        if (info == null || !info.hasName) {
          if (current != null && info != null) {
            if (current.room.isEmpty && info.room.isNotEmpty) {
              current.room = info.room;
            }
            if (current.teacher.isEmpty && info.teacher.isNotEmpty) {
              current.teacher = info.teacher;
            }
            if (!(info.startWeek == 1 && info.endWeek == 16)) {
              current.startWeek = info.startWeek;
              current.endWeek = info.endWeek;
            }
            // 续行里明写节次（如「7-8节」）时用它修正
            final Match? pm = rePeriodRange.firstMatch(part.lines.join(' '));
            if (pm != null) {
              final int a = int.parse(pm.group(1)!);
              final int b = int.parse(pm.group(2)!);
              current.startPeriod =
                  current.startPeriod < a ? current.startPeriod : a;
              current.endPeriod = current.endPeriod > b ? current.endPeriod : b;
              current.explicitPeriod = true;
            } else if (!current.explicitPeriod) {
              if (period > current.endPeriod) current.endPeriod = period;
            }
          }
          continue;
        }

        // 同名且节次紧邻才算同一门课的续行
        final bool same = current != null &&
            info.name == current.name &&
            period == current.endPeriod + 1;

        if (same) {
          if (current.room.isEmpty && info.room.isNotEmpty) {
            current.room = info.room;
          }
          if (current.teacher.isEmpty && info.teacher.isNotEmpty) {
            current.teacher = info.teacher;
          }
          if (current.defaultWeeks() &&
              !(info.startWeek == 1 && info.endWeek == 16)) {
            current.startWeek = info.startWeek;
            current.endWeek = info.endWeek;
          }
          if (!current.explicitPeriod && period > current.endPeriod) {
            current.endPeriod = period;
          }
        } else {
          final _Building b = _Building()
            ..name = info.name
            ..teacher = info.teacher
            ..room = info.room
            ..weekday = wd
            ..startWeek = info.startWeek
            ..endWeek = info.endWeek
            ..explicitPeriod =
                rePeriodRange.hasMatch(part.lines.join(' '));
          int sp = info.startPeriod ?? period;
          int ep = info.endPeriod ?? period;
          if (ep < sp) {
            final int t = sp;
            sp = ep;
            ep = t;
          }
          b.startPeriod = sp;
          b.endPeriod = ep;
          builders.add(b);
          current = b;
        }
      }
    }
  }

  // 到这里所有「续行补充」都已完成，再统一生成 Course
  for (final _Building b in builders) {
    result.add(_toCourse(b, seq++));
  }

  // 过滤噪声：只有地点/教师没有课名的碎片
  final List<Course> clean = result.where((Course c) {
    if (c.name.isEmpty) return false;
    return true;
  }).toList();

  clean.sort((Course a, Course b) {
    final int w = a.weekday.compareTo(b.weekday);
    return w != 0 ? w : a.startPeriod.compareTo(b.startPeriod);
  });

  return CellParseResult(
    courses: clean,
    periods: periods,
    warnings: warnings,
    cells: cells,
  );
}

Course _toCourse(_Building b, int seq) {
  final String roomFixed = b.room.trim();
  final String teacherFixed = b.teacher.trim();
  return Course(
    id: 'pp_${DateTime.now().microsecondsSinceEpoch}_$seq',
    name: b.name.trim(),
    weekday: b.weekday,
    startPeriod: b.startPeriod,
    endPeriod: b.endPeriod,
    room: roomFixed,
    teacher: teacherFixed,
    startWeek: b.startWeek,
    endWeek: b.endWeek,
    weekType: 'all',
  );
}
