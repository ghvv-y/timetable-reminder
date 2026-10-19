// 从教务系统网页「复制文本」直接解析课表
//
// 为什么这是主路径：
//   截图 OCR 是在猜像素，最好也就 78%；而复制出来的文本是系统给的，
//   准确率 100%，而且用户操作更快（长按全选复制 vs 截图选图等识别）。
//
// 兼容两类教务系统文本：
//   1. URP（金智）的「全部课程清单」——最精确，用 >> 分隔
//        2640706001	高等数学A(1)	...	张怡通*	...	3-16周>>星期二>>1-2节	校本部>>3号教学楼>>3-310
//   2. 通用「一行一门课」文本——其他教务系统常见
//        大学英语（1）_33  黄怡凡  周一 1-2节 7-8周  冷链-A202
//
// 都解析不出来时返回 null，让调用方提示用户。

import '../model/models.dart';
import '../model/period_time.dart';

/// 粘贴文本的解析结果
class PasteParseResult {
  final List<Course> courses;
  final List<PeriodTime> periods;
  final List<String> warnings;

  /// 命中哪套规则（界面显示用）
  final String format;

  const PasteParseResult({
    required this.courses,
    required this.periods,
    this.warnings = const <String>[],
    this.format = '',
  });

  bool get isEmpty => courses.isEmpty && periods.isEmpty;
}

// ---------------- 正则 ----------------

/// 课程行首：课程号（6+ 位数字）+ 分隔符
///
/// 【为什么允许空格】安卓剪贴板在部分机型/浏览器上会把制表符
/// 转换成空格。若只认 \t，这些用户复制出来的文本会整段解析失败。
final RegExp _reCourseHead = RegExp(r'^\s*(\d{6,})[\t ]');

/// 时间三元组：周次>>星期>>节次
final RegExp _reTriple =
    RegExp(r'([\d][\d,\-]*周?)\s*>>\s*(星期[一二三四五六日天])\s*>>\s*([\d\-]+节)');

/// 地点三元组：校区>>楼>>房间
final RegExp _rePlace = RegExp(r'([^\t>]*)>>([^\t>]*)>>([^\t>]*)');

/// 时间区间：第(08:00-08:45)
final RegExp _reTimeRange = RegExp(
    r'(\d{1,2})\s*[:：]\s*(\d{2})\s*[-—–~～至到]\s*(\d{1,2})\s*[:：]\s*(\d{2})');

/// 周次表达式
final RegExp _reWeekExpr = RegExp(r'(\d{1,2}(?:\s*-\s*\d{1,2})?(?:\s*,\s*\d{1,2}(?:\s*-\s*\d{1,2})?)*)\s*周');

/// 节次表达式
final RegExp _rePeriodRange = RegExp(r'(\d{1,2})\s*-\s*(\d{1,2})\s*节');

const Map<String, int> _weekdayMap = <String, int>{
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
};

// ---------------- 周次 ----------------

/// 解析出的周次信息
class WeekSpec {
  final int startWeek;
  final int endWeek;
  final String weekType; // all / odd / even

  const WeekSpec(this.startWeek, this.endWeek, this.weekType);

  @override
  String toString() => '$startWeek-$endWeek($weekType)';
}

/// 把周次表达式拆成若干段 WeekSpec。
///
/// 为什么要拆：Course 模型只能表示「连续区间 + 单双周」，
/// 而「3-4,6-10周」这种不连续区间必须拆成两条课程记录。
///
/// [semesterMax] 学期总周数，用于判断「单双周列表」的结束周。
/// [warnings] 传非空列表时，补齐/异常会追加说明（供界面提示）。
List<WeekSpec> parseWeekExpr(
  String expr, {
  int semesterMax = 16,
  List<String>? warnings,
}) {
  // 去掉「第」「周」等修饰，只留数字、逗号、连字符
  final String s = expr.replaceAll(RegExp(r'[^\d,\-]'), '');
  if (s.isEmpty) return const <WeekSpec>[];

  final List<WeekSpec> out = <WeekSpec>[];
  final List<String> parts = s.split(',');

  for (final String part in parts) {
    if (part.isEmpty) continue;
    if (part.contains('-')) {
      final List<String> ab = part.split('-');
      if (ab.length != 2) continue;
      final int? a = int.tryParse(ab[0]);
      final int? b = int.tryParse(ab[1]);
      if (a == null || b == null) continue;
      final int lo = a <= b ? a : b;
      final int hi = a <= b ? b : a;
      if (lo < 1 || hi > 30) continue;
      out.add(WeekSpec(lo, hi, 'all'));
    } else {
      final int? n = int.tryParse(part);
      if (n == null || n < 1 || n > 30) continue;
      out.add(WeekSpec(n, n, 'all'));
    }
  }

  // 单周 / 双周列表合并：3,5,7,9,11,13,15 或 4,6,8,10,12,14,16
  //
  // 【为什么要求 ≥4 项】3 项的等差列表（如 3,5,7）也可能是「真的只上
  // 这几周」的短列表，贸然推断成单周到学期末会**多生成提醒**——这比
  // 漏提醒更烦人。教务系统输出的完整单双周列表一般 ≥7 项，4 项是
  // 「OCR 截断」和「真实短列表」之间较稳的分界。
  if (out.length >= 4 && out.every((WeekSpec w) => w.startWeek == w.endWeek)) {
    final List<int> nums = out.map((WeekSpec w) => w.startWeek).toList()..sort();
    bool step2 = true;
    for (int i = 1; i < nums.length; i++) {
      if (nums[i] - nums[i - 1] != 2) {
        step2 = false;
        break;
      }
    }
    if (step2 && nums.isNotEmpty) {
      final bool odd = nums.first.isOdd;
      // 列表可能被截断，按学期末补齐
      int end = nums.last;
      while (end + 2 <= semesterMax) {
        end += 2;
      }
      if (end > nums.last) {
        warnings?.add(
            '周次「$expr」疑似不完整，已按${odd ? '单' : '双'}周补齐到第 $end 周，请核对');
      }
      return <WeekSpec>[WeekSpec(nums.first, end, odd ? 'odd' : 'even')];
    }
  }

  // 相邻单周合并成区间（如「第3周」「第4周」→ 3-4）
  final List<WeekSpec> merged = <WeekSpec>[];
  for (final WeekSpec w in out) {
    if (merged.isNotEmpty &&
        merged.last.weekType == 'all' &&
        w.weekType == 'all' &&
        w.startWeek == merged.last.endWeek + 1) {
      final WeekSpec last = merged.removeLast();
      merged.add(WeekSpec(last.startWeek, w.endWeek, 'all'));
    } else {
      merged.add(w);
    }
  }
  return merged;
}

// ---------------- 时间栏 ----------------

/// 从文本里提取作息时间（第(HH:MM-HH:MM)）
List<PeriodTime> parsePeriodsFromText(String text) {
  final List<PeriodTime> out = <PeriodTime>[];
  final Set<String> seen = <String>{};
  for (final RegExpMatch m in _reTimeRange.allMatches(text)) {
    final int sh = int.parse(m.group(1)!);
    final int sm = int.parse(m.group(2)!);
    final int eh = int.parse(m.group(3)!);
    final int em = int.parse(m.group(4)!);
    final int start = sh * 60 + sm;
    final int end = eh * 60 + em;
    if (start < 0 || start > 1439 || end <= start) continue;
    final String key = '$start-$end';
    if (seen.contains(key)) continue;
    seen.add(key);
    out.add(PeriodTime(
      period: out.length + 1,
      startMinute: start,
      endMinute: end,
    ));
  }
  return out;
}

// ---------------- URP 格式 ----------------

/// 解析 URP「全部课程清单」格式
PasteParseResult? _parseUrp(String text) {
  final List<String> lines = text.split(RegExp(r'[\r\n]+'));

  // 必须至少有 2 门课的行首课程号，才认为命中
  final int headCount = lines.where((String l) => _reCourseHead.hasMatch(l)).length;
  if (headCount < 2) return null;

  final List<Course> courses = <Course>[];
  final List<String> warnings = <String>[];
  int seq = 0;

  String? curName;
  String curTeacher = '';

  void addEntry(String weekExpr, String weekdayText, String periodText, String room) {
    if (curName == null) return;
    final String dayChar = weekdayText.replaceAll('星期', '');
    final int? wd = _weekdayMap[dayChar];
    if (wd == null) return;

    final List<WeekSpec> weeks = parseWeekExpr(weekExpr, warnings: warnings);
    if (weeks.isEmpty) {
      warnings.add('「$curName」的周次「$weekExpr」解析失败，已按全学期处理');
    }

    int sp = 1;
    int ep = 2;
    final RegExpMatch? pm = _rePeriodRange.firstMatch(periodText);
    if (pm != null) {
      final int a = int.parse(pm.group(1)!);
      final int b = int.parse(pm.group(2)!);
      sp = a <= b ? a : b;
      ep = a <= b ? b : a;
    }

    final List<WeekSpec> use = weeks.isEmpty
        ? <WeekSpec>[const WeekSpec(1, 16, 'all')]
        : weeks;
    for (final WeekSpec w in use) {
      courses.add(Course(
        id: 'paste_${seq++}',
        name: curName,
        weekday: wd,
        startPeriod: sp,
        endPeriod: ep,
        room: room,
        teacher: curTeacher,
        startWeek: w.startWeek,
        endWeek: w.endWeek,
        weekType: w.weekType,
      ));
    }
  }

  for (final String line in lines) {
    final bool isHead = _reCourseHead.hasMatch(line);
    if (isHead) {
      // 制表符可能被剪贴板转成空格：有 \t 按 \t 切（保留空字段），
      // 没有则按 2+ 连续空格切（空字段本来就是空的，不影响列对齐）。
      // 先 trim，防止行首空白把第一列挤成空串。
      final String body = line.trim();
      final List<String> f = body.contains('\t')
          ? body.split('\t')
          : body.split(RegExp(r'\s{2,}'));
      curName = f.length > 1 ? f[1].trim() : '';
      curTeacher = '';
      // 教师字段：带星号的短字段（排除时间/地点三元组）
      for (final String cell in f) {
        final String c = cell.trim();
        if (c.contains('>>')) continue;
        if (c.isEmpty) continue;
        if (c.endsWith('*') && c.length <= 12) {
          curTeacher = c;
          break;
        }
      }
      // 教师可能写成「艾娟* 王丛」
      if (curTeacher.isEmpty) {
        for (final String cell in f) {
          final String c = cell.trim();
          if (c.contains('>>') || c.contains('周')) continue;
          if (c.contains('*') && c.length <= 14) {
            curTeacher = c;
            break;
          }
        }
      }
      if (curName.isEmpty) {
        curName = null;
        continue;
      }
      // 同一行里也可能带时间/地点
      final Match? t = _reTriple.firstMatch(line);
      if (t != null) {
        final Match? pl = _rePlace.firstMatch(line.substring(t.end));
        addEntry(t.group(1)!, t.group(2)!, t.group(3)!, _joinPlace(pl));
      }
    } else if (curName != null) {
      final Match? t = _reTriple.firstMatch(line);
      if (t != null) {
        final Match? pl = _rePlace.firstMatch(line.substring(t.end));
        addEntry(t.group(1)!, t.group(2)!, t.group(3)!, _joinPlace(pl));
      }
    }
  }

  if (courses.isEmpty) return null;

  final List<PeriodTime> periods = parsePeriodsFromText(text);
  return PasteParseResult(
    courses: _dedupe(courses),
    periods: periods,
    warnings: warnings,
    format: 'URP 课程清单',
  );
}

String _joinPlace(Match? m) {
  if (m == null) return '';
  final List<String> parts = <String>[m.group(1) ?? '', m.group(2) ?? '', m.group(3) ?? '']
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
  return parts.join(' ');
}

// ---------------- 通用「一行一门课」格式 ----------------

final RegExp _reAnyWeekday = RegExp(r'周([一二三四五六日天])');
final RegExp _reAnyPeriod = RegExp(r'(\d{1,2})\s*[-～~]\s*(\d{1,2})\s*节');

PasteParseResult? _parseGeneric(String text) {
  final List<String> lines = text.split(RegExp(r'[\r\n]+'));
  final List<Course> courses = <Course>[];
  int seq = 0;

  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.length < 6) continue;
    final Match? wdm = _reAnyWeekday.firstMatch(line);
    final Match? pm = _reAnyPeriod.firstMatch(line);
    if (wdm == null || pm == null) continue;

    final int wd = _weekdayMap[wdm.group(1)] ?? 0;
    if (wd == 0) continue;

    final Match? wm = _reWeekExpr.firstMatch(line);
    final List<WeekSpec> weeks =
        wm == null ? <WeekSpec>[const WeekSpec(1, 16, 'all')] : parseWeekExpr(wm.group(1)!);

    // 课程名：去掉星期/节次/周次后，剩下的中文片段里取最长的一个。
    // 【坑】地点往往比课名长（「体育」vs「校本部体育场风雨操场…」），
    // 直接取最长会拿到地点。所以先把明显像地点的片段滤掉。
    String name = line
        .replaceAll(wdm.group(0)!, '')
        .replaceAll(pm.group(0)!, '')
        .replaceAll(wm?.group(0) ?? '~~', '');
    final List<String> tokens = name
        .split(RegExp(r'[\s\t,，|]+'))
        .where((String s) => s.trim().isNotEmpty)
        .where((String s) =>
            !RegExp(r'楼|馆|厅|场|号|室|园|校部').hasMatch(s))
        .toList();
    if (tokens.isEmpty) continue;
    tokens.sort((String a, String b) => b.length.compareTo(a.length));
    name = tokens.first;

    final int a = int.parse(pm.group(1)!);
    final int b = int.parse(pm.group(2)!);
    final int sp = a <= b ? a : b;
    final int ep = a <= b ? b : a;

    for (final WeekSpec w in weeks) {
      courses.add(Course(
        id: 'paste_${seq++}',
        name: name,
        weekday: wd,
        startPeriod: sp,
        endPeriod: ep,
        startWeek: w.startWeek,
        endWeek: w.endWeek,
        weekType: w.weekType,
      ));
    }
  }

  if (courses.length < 2) return null;
  return PasteParseResult(
    courses: _dedupe(courses),
    periods: parsePeriodsFromText(text),
    format: '通用文本',
  );
}

List<Course> _dedupe(List<Course> input) {
  final Set<String> seen = <String>{};
  final List<Course> out = <Course>[];
  for (final Course c in input) {
    final String key =
        '${c.name}|${c.weekday}|${c.startPeriod}|${c.endPeriod}|${c.startWeek}|${c.endWeek}|${c.weekType}';
    if (seen.add(key)) out.add(c);
  }
  out.sort((Course a, Course b) {
    final int w = a.weekday.compareTo(b.weekday);
    if (w != 0) return w;
    return a.startPeriod.compareTo(b.startPeriod);
  });
  return out;
}

// ---------------- 入口 ----------------

/// 解析粘贴的课表文本。返回 null 表示识别不出课表。
PasteParseResult? parsePastedSchedule(String text) {
  if (text.trim().isEmpty) return null;
  return _parseUrp(text) ?? _parseGeneric(text);
}
