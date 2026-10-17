// 课表识别解析器（第 2、3 阶段的算法）
//
// 目标：从识别出的文字块中，同时理解两件事
//   1. 课程格：「课程名 + 星期 + 第几节 + 地点」
//   2. 边侧时间栏：「第几节 = 几点到几点」
// 再把二者对齐，从而推算出：
//   上课前 N 分钟 = 节次开始时间 - N
//   下课前 N 分钟 = 节次结束时间 - N
//
// 兼容的真实写法：
//   时间栏：第1节 08:00-08:45 / 1-2节 08:00-09:40 / 08:00-08:45（单独一行）
//   课程格：数据结构 / 数据结构 教三301 / (3-4节)数据结构 / 第3、4节 大学英语

import '../model/models.dart';
import '../model/period_time.dart';
import '../utils/time_utils.dart';

/// 带坐标的文字块（坐标归一化到 0-1，便于适配不同分辨率）
class TextBlock {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const TextBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  @override
  String toString() => 'TextBlock("$text", x=$centerX, y=$centerY)';
}

/// 解析结果
class ParseResult {
  /// 作息时间表：第几节 = 几点到几点
  final List<PeriodTime> periodTimes;

  /// 课程列表
  final List<Course> courses;

  /// 需要用户重点核对的时间项（低置信度）
  final List<String> warnings;

  const ParseResult({
    this.periodTimes = const <PeriodTime>[],
    this.courses = const <Course>[],
    this.warnings = const <String>[],
  });

  bool get isEmpty => courses.isEmpty && periodTimes.isEmpty;
}

class TableParser {
  /// 节次关键词：兼容多种真实写法
  ///   第1节 / 1-2节 / 3、4节 / (3-4) / 第10节
  static final RegExp _periodWord =
      RegExp(r'第?\s*(\d{1,2})(?:\s*[-—~至到、,，]\s*(\d{1,2}))*\s*节');

  /// 中文数字节次：第一节 / 第十节
  static final RegExp _periodChineseWord =
      RegExp(r'第?\s*([一二三四五六七八九十]{1,3})\s*节');

  /// 时间区间，例如 08:00-08:45、8:00~8:45
  /// 兼容 OCR 常见的多种连字符：- — – ~ ～ 至 到 ·
  static final RegExp _timeRange = RegExp(
      r'(\d{1,2}\s*[:：.]\s*\d{2})\s*[-—–~～‒−ー至到]\s*(\d{1,2}\s*[:：.]\s*\d{2})');

  /// 单独一个时间点，例如 08:00
  static final RegExp _timePoint = RegExp(r'(\d{1,2}\s*[:：.]\s*\d{2})');

  /// 该行是否含时间区间
  static bool _hasRange(String text) => _timeRange.hasMatch(text);

  /// 时间栏行：含时间点，且不含明显的课程特征
  static bool _looksLikeTimeRow(String text) {
    if (!_timePoint.hasMatch(text)) return false;
    if (_hasRange(text)) return true;
    // 只有单个时间点：长度很短、且只有数字/时间标点，才算时间栏
    final String rest = text.replaceAll(_timePoint, '').trim();
    return rest.length <= 4;
  }

  /// 把被 OCR 拆散的时间点合成区间
  ///
  /// 两种情况要分开处理：
  ///
  /// A) **同一行里有两个时间点但连字符丢了**（如「08:00 08:45」）
  ///    所有场合都安全，直接合并。
  ///
  /// B) **连字符被拆到上下两行**（如上一行「08:00」、下一行「08:45」）
  ///    只在课表**没有节次标签**时才启用。
  ///    因为像「第1(08:00-08:45)」「第2(08:50-09:35)」这种表，
  ///    横向相邻的两个节次行纵距很近，做纵向配对会把第1节的开始时间
  ///    和第2节的开始时间错配成一个假区间，污染整张作息表。
  static List<TextBlock> _pairTimeBlocks(List<TextBlock> blocks) {
    final List<TextBlock> merged = <TextBlock>[];

    // ---------- A) 同一行内两个时间点 ----------
    for (final TextBlock b in blocks) {
      if (_hasRange(b.text)) continue;
      final List<RegExpMatch> points =
          _timePoint.allMatches(b.text).toList(growable: false);
      if (points.length != 2) continue;
      final int? a = parseMinute(points[0].group(1)!);
      final int? c = parseMinute(points[1].group(1)!);
      if (a == null || c == null || c <= a || c - a > 180) continue;
      merged.add(TextBlock(
        text: '${fmtMinute(a)}-${fmtMinute(c)}',
        left: b.left,
        top: b.top,
        right: b.right,
        bottom: b.bottom,
      ));
    }

    // ---------- B) 上下两行的时间点（仅无节次标签时） ----------
    final bool hasPeriodLabels = blocks.any((TextBlock b) => _hasPeriod(b.text));
    if (hasPeriodLabels) return merged;

    final List<TextBlock> pointsOnly = blocks
        .where((TextBlock b) =>
            _timePoint.hasMatch(b.text) && !_hasRange(b.text))
        .toList()
      ..sort((TextBlock a, TextBlock b) => a.centerY.compareTo(b.centerY));
    if (pointsOnly.length < 2) return merged;

    final Set<int> used = <int>{};
    for (int i = 0; i < pointsOnly.length; i++) {
      if (used.contains(i)) continue;
      final TextBlock upper = pointsOnly[i];
      final int? a = parseMinute(_timePoint.firstMatch(upper.text)!.group(1)!);
      if (a == null) continue;

      int? partner;
      for (int j = i + 1; j < pointsOnly.length; j++) {
        if (used.contains(j)) continue;
        final TextBlock lower = pointsOnly[j];
        final double gapY = lower.centerY - upper.centerY;
        if (gapY <= 0) continue;
        // 必须纵向紧挨着，且横向大致对齐（才像被拆开的同一个区间）
        if (gapY > 0.04 ||
            (lower.centerX - upper.centerX).abs() > 0.12) {
          break;
        }
        final int? c =
            parseMinute(_timePoint.firstMatch(lower.text)!.group(1)!);
        if (c == null || c <= a) continue;
        partner = j;
        break;
      }
      if (partner == null) continue;

      used.add(i);
      used.add(partner);
      final int c =
          parseMinute(_timePoint.firstMatch(pointsOnly[partner].text)!.group(1)!)!;
      merged.add(TextBlock(
        text: '${fmtMinute(a)}-${fmtMinute(c)}',
        left: upper.left,
        top: upper.top,
        right: upper.right,
        bottom: pointsOnly[partner].bottom,
      ));
    }
    return merged;
  }

  /// 中文数字转阿拉伯数字
  static int _cnNum(String s) {
    const Map<String, int> map = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    final int? direct = int.tryParse(s);
    if (direct != null) return direct;
    if (s == '十一') return 11;
    if (s == '十二') return 12;
    if (s.startsWith('十')) {
      return 10 + (map[s.substring(1)] ?? 0);
    }
    return map[s] ?? 0;
  }

  /// 提取一行文字里的节次（返回 [起始节, 结束节]）
  ///
  /// 为什么不用一条复杂正则：真实课表里节次后面常紧跟括号里的时间，
  /// 例如「第2(08:50-09:35)」。实测有两种坑：
  ///   1. `(\d)(?:[-、](\d))*节` 这类带重复组的写法，正则回溯时会匹配到
  ///      时间里的数字（把 08 当成第二个节次）；
  ///   2. 抠掉时间后剩「第2( - )」，若数字提取允许空匹配，会先把 0 塞进来，
  ///      再被 `n > 0` 过滤，结果一个节次都读不到。
  ///
  /// 这里改用「从『节』字往前爬」的方式，逐个位置取最长数字串，稳定可靠。
  static List<int> _extractPeriods(String text) {
    // 1) 抠掉时间区间与时间点，避免时间里的数字被当成节次
    final String cleaned =
        text.replaceAll(_timeRange, ' ').replaceAll(_timePoint, ' ');

    final List<int> nums = <int>[];

    // 2) 取「节」字前的那些数字
    int searchFrom = 0;
    while (true) {
      final int jie = cleaned.indexOf('节', searchFrom);
      if (jie < 0) break;

      // 向前跨过空白，要求在数字前面（或紧邻）。end < 0 说明前面是「第」或行首。
      int i = jie - 1;
      while (i >= 0 && _isSpace(cleaned[i])) {
        i--;
      }
      if (i >= 0 && !_isDigit(cleaned[i]) && cleaned[i] != '第') {
        searchFrom = jie + 1;
        continue;
      }

      while (i >= 0 && (_isDigit(cleaned[i]) || _isSep(cleaned[i]))) {
        i--;
      }
      final String run = cleaned.substring(i + 1, jie);
      for (final RegExpMatch d in RegExp(r'\d{1,2}').allMatches(run)) {
        final int? n = int.tryParse(d.group(0)!);
        if (n != null && n > 0 && n <= 30) nums.add(n);
      }
      searchFrom = jie + 1;
    }

    // 3) 中文数字写法（如「第三节」）
    if (nums.isEmpty) {
      for (final RegExpMatch m in _periodChineseWord.allMatches(cleaned)) {
        final int n = _cnNum(m.group(1)!);
        if (n > 0 && n <= 30) nums.add(n);
      }
    }

    if (nums.isEmpty) return const <int>[];
    if (nums.length == 1) return <int>[nums.first, nums.first];
    return <int>[nums.first, nums.last];
  }

  static bool _isDigit(String c) {
    final int code = c.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\u3000' || c == '\t';

  static bool _isSep(String c) =>
      c == '-' ||
      c == '—' ||
      c == '–' ||
      c == '~' ||
      c == '～' ||
      c == '、' ||
      c == ',' ||
      c == '，';

  /// 该行是否含节次标记
  static bool _hasPeriod(String text) =>
      _periodWord.hasMatch(text) || _periodChineseWord.hasMatch(text);

  /// 从文字块中提取「第几节 = 几点到几点」
  ///
  /// 依据：时间栏通常位于课表左侧或顶部，文字形如
  ///   「第1节 08:00-08:45」或「08:00-08:45」单独一行（此时按位置与节次标签配对）。
  static List<PeriodTime> parsePeriodTimes(
    List<TextBlock> blocks, {
    double sideThreshold = 0.32,
  }) {
    final Map<int, PeriodTime> result = <int, PeriodTime>{};

    // 先把被 OCR 拆散的时间点合成区间（例如上下两行的 08:00 / 08:45）
    final List<TextBlock> paired = _pairTimeBlocks(blocks);
    final List<TextBlock> all = <TextBlock>[...blocks, ...paired];

    // 1) 同一行里既有节次又有时间区间，直接配对
    for (final TextBlock b in all) {
      final Match? tr = _timeRange.firstMatch(b.text);
      if (tr == null) continue;
      final List<int> periods = _extractPeriods(b.text);
      if (periods.isEmpty) continue;
      final int? s = parseMinute(tr.group(1)!);
      final int? e = parseMinute(tr.group(2)!);
      if (s == null || e == null) continue;
      result[periods.first] = PeriodTime(
        period: periods.first,
        startMinute: s,
        endMinute: e,
      );
    }

    // 2) 只有时间区间，需要用纵向位置与「第 N 节」标签配对
    final List<TextBlock> timeOnly = all.where((TextBlock b) {
      return _hasRange(b.text) && !_hasPeriod(b.text);
    }).toList();

    final List<TextBlock> periodOnly = all.where((TextBlock b) {
      return _hasPeriod(b.text) && !_hasRange(b.text);
    }).toList();

    for (final TextBlock t in timeOnly) {
      final Match? tr = _timeRange.firstMatch(t.text);
      if (tr == null) continue;

      TextBlock? best;
      double bestDist = double.infinity;
      for (final TextBlock p in periodOnly) {
        final double d = (p.centerY - t.centerY).abs();
        if (d < bestDist) {
          bestDist = d;
          best = p;
        }
      }
      // 纵向容差 0.08：既要能对上「节次标签居中、时间在其下方」的版式，
      // 又不能大到把相邻两行错配（实测 0.05 会漏配，0.10 会错配）
      if (best == null || bestDist > 0.08) continue;

      final List<int> periods = _extractPeriods(best.text);
      if (periods.isEmpty) continue;

      final int? s = parseMinute(tr.group(1)!);
      final int? e = parseMinute(tr.group(2)!);
      if (s == null || e == null) continue;

      if (!result.containsKey(periods.first)) {
        result[periods.first] = PeriodTime(
          period: periods.first,
          startMinute: s,
          endMinute: e,
        );
      }
    }

    // 3) 兜底：整张表只有一串时间区间，按出现顺序依次编号
    if (result.isEmpty && timeOnly.isNotEmpty) {
      int idx = 1;
      for (final TextBlock t in timeOnly) {
        final Match? tr = _timeRange.firstMatch(t.text);
        if (tr == null) continue;
        final int? s = parseMinute(tr.group(1)!);
        final int? e = parseMinute(tr.group(2)!);
        if (s == null || e == null) continue;
        result[idx] = PeriodTime(period: idx, startMinute: s, endMinute: e);
        idx++;
      }
    }

    final List<PeriodTime> list = result.values.toList()
      ..sort((PeriodTime a, PeriodTime b) => a.period.compareTo(b.period));
    return list;
  }

  // ---------------- 坐标结构：把课表当成表格来理解 ----------------

  /// 课表里的「一行」：某节课在时间轴上的纵向位置
  static List<_TimeRow> _buildTimeRows(List<TextBlock> blocks) {
    final List<_TimeRow> rows = <_TimeRow>[];
    for (final TextBlock b in blocks) {
      final Match? tr = _timeRange.firstMatch(b.text);
      if (tr == null) continue;
      // 含时间区间的行不参加星期判定（避免把时间栏误当成一列）
      rows.add(_TimeRow(
        top: b.top,
        bottom: b.bottom,
        y: b.centerY,
        startMinute: parseMinute(tr.group(1)!),
        endMinute: parseMinute(tr.group(2)!),
      ));
    }
    rows.sort((_TimeRow a, _TimeRow b) => a.y.compareTo(b.y));
    return rows;
  }

  /// 星期表头锚点
  ///
  /// 定位策略（按可靠性排序）：
  ///   1. 表头一定在图片上部，先在纵向 22% 以内找；
  ///   2. 在候选中按 y 聚成几行，取「能认出的不同星期个数最多」的那一行；
  ///   3. 都不理想时退回「全图找、按 x 从左到右补齐」。
  ///
  /// 之前只看「同一 y 波段命中最多」，但课程格里的「7-8周」「3-16周」也含
  /// 「周」字，会和表头抢位置；加个「只在上部找」的限制后就稳了。
  static List<_WeekdayAnchor> _weekdayAnchors(List<TextBlock> blocks) {
    // 【关键】必须同时匹配「周一」和「星期一」！
    // 很多教务系统的表头写的是「星期X」而不是「周X」，
    // 之前只找「周」，导致一个表头都认不出来，全部课程被迫按列顺序硬猜。
    final RegExp re = RegExp(r'[周星]\s*[期]?\s*([一二三四五六日天])');
    const Map<String, int> wd = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7,
    };

    // 只认短文本：表头是「周一」「星期一」，课程格里的长句排除掉
    bool looksLikeHeader(TextBlock b) {
      final String t = b.text.trim();
      if (t.length > 6) return false;
      return re.hasMatch(t);
    }

    final List<TextBlock> all =
        blocks.where(looksLikeHeader).toList(growable: false);
    if (all.isEmpty) return <_WeekdayAnchor>[];

    // 优先上部区域
    final List<TextBlock> upper =
        all.where((TextBlock b) => b.centerY <= 0.22).toList(growable: false);

    List<_WeekdayAnchor> pick(List<TextBlock> pool) {
      if (pool.isEmpty) return <_WeekdayAnchor>[];

      // 按 y 聚类，得到候选表头行
      final List<TextBlock> sorted = List<TextBlock>.from(pool)
        ..sort((TextBlock a, TextBlock b) => a.centerY.compareTo(b.centerY));

      List<_WeekdayAnchor> best = <_WeekdayAnchor>[];
      final List<TextBlock> band = <TextBlock>[];
      double bandTop = sorted.first.centerY;

      void flush() {
        if (band.isEmpty) return;
        final Map<int, _WeekdayAnchor> byDay = <int, _WeekdayAnchor>{};
        for (final TextBlock b in band) {
          final Match? m = re.firstMatch(b.text);
          if (m == null) continue;
          final int? day = wd[m.group(1)!];
          if (day == null) continue;
          // 同一个星期名只保留最靠左的那个（表头）
          final _WeekdayAnchor? exist = byDay[day];
          if (exist == null || b.centerX < exist.x) {
            byDay[day] = _WeekdayAnchor(weekday: day, x: b.centerX);
          }
        }
        if (byDay.length > best.length) {
          best = byDay.values.toList();
        }
      }

      for (final TextBlock b in sorted) {
        if ((b.centerY - bandTop).abs() > 0.045) {
          flush();
          band.clear();
          bandTop = b.centerY;
        }
        band.add(b);
      }
      flush();

      best.sort((_WeekdayAnchor a, _WeekdayAnchor b) => a.x.compareTo(b.x));
      return best;
    }

    final List<_WeekdayAnchor> fromUpper = pick(upper);
    if (fromUpper.length >= 2) return fromUpper;

    // 上部落空：全图找（有些截图上方有水印或标题，星期行会更靠下）
    final List<_WeekdayAnchor> fromAll = pick(all);
    // 保留不同星期，按 x 排序
    final Map<int, _WeekdayAnchor> merged = <int, _WeekdayAnchor>{};
    for (final _WeekdayAnchor a in fromAll) {
      final _WeekdayAnchor? exist = merged[a.weekday];
      if (exist == null || a.x < exist.x) merged[a.weekday] = a;
    }
    final List<_WeekdayAnchor> out = merged.values.toList()
      ..sort((_WeekdayAnchor a, _WeekdayAnchor b) => a.x.compareTo(b.x));
    return out;
  }

  /// 候选课程块的横向位置（排除时间栏、星期表头、纯节次标签）
  static List<double> _columnCandidates(List<TextBlock> blocks) {
    final List<double> xs = <double>[];
    for (final TextBlock b in blocks) {
      final String t = b.text.trim();
      if (t.isEmpty || t.length < 2) continue;
      if (_looksLikeTimeRow(t) && !_hasPeriod(t)) continue;
      if (RegExp(r'^[周星]\s*[期]?\s*[一二三四五六日天]$').hasMatch(t)) continue;
      if (RegExp(r'^\d{1,2}[:：.]?\d{0,2}$').hasMatch(t)) continue;
      // 纯节次标签（第1节 / 1-2节）不是课程格
      final String withoutPeriod = _hasPeriod(t)
          ? t
              .replaceAll(_periodWord, '')
              .replaceAll(_periodChineseWord, '')
              .replaceAll(RegExp(r'[\s\-—,，、.。()（）\[\]]'), '')
              .trim()
          : t;
      if (withoutPeriod.isEmpty) continue;
      xs.add(b.centerX);
    }
    return xs;
  }

  /// 一维聚类：把接近的横坐标合成一列
  static List<double> _clusterX(List<double> xs) {
    if (xs.isEmpty) return <double>[];
    xs.sort();
    final List<double> centers = <double>[];
    double sum = xs.first;
    int count = 1;
    for (int i = 1; i < xs.length; i++) {
      if (xs[i] - xs[i - 1] <= 0.05) {
        sum += xs[i];
        count++;
      } else {
        centers.add(sum / count);
        sum = xs[i];
        count = 1;
      }
    }
    centers.add(sum / count);
    return centers;
  }

  /// 检测课表的「列」，并给出每一列对应的星期
  ///
  /// 分三种情况，越靠前越可靠（返回值第二项表示星期是否是推测的）：
  ///   1. 表头认全了 → 直接按表头位置定位各列，星期取自表头
  ///   2. 表头只认出一部分 → 用表头位置确定列中心，星期按从左到右的顺序补
  ///   3. 表头完全没认出来 → 按课程块的横向位置聚类出列，从左到右对应周一起
  ///
  /// 关键点：表头文字本身**不能**参与列聚类，否则会多出一列导致整体错位。
  static (List<double>, bool) _detectColumns(
    List<TextBlock> blocks,
    Map<int, int> weekdayByIndex,
  ) {
    final List<_WeekdayAnchor> anchors = _weekdayAnchors(blocks);
    final List<double> candidates = _columnCandidates(blocks);
    if (candidates.isEmpty) return (<double>[], false);

    // 情况 1：表头认全了 5 列以上，直接用表头位置与星期
    if (anchors.length >= 5) {
      for (int i = 0; i < anchors.length; i++) {
        weekdayByIndex[i] = anchors[i].weekday;
      }
      return (anchors.map((_WeekdayAnchor a) => a.x).toList(), false);
    }

    // 表头有定位（但可能不全）：以表头位置为基准确定各列中心
    if (anchors.isNotEmpty) {
      final List<double> anchorXs =
          anchors.map((_WeekdayAnchor a) => a.x).toList()..sort();
      // 用课程块的横向跨度估算列间距
      final List<double> cols = _clusterX(candidates);
      double step = 0.2;
      if (cols.length >= 2) {
        final List<double> diffs = <double>[];
        for (int i = 1; i < cols.length; i++) {
          if (cols[i] - cols[i - 1] > 0.05) diffs.add(cols[i] - cols[i - 1]);
        }
        if (diffs.isNotEmpty) {
          step = diffs.reduce((double a, double b) => a + b) / diffs.length;
        }
      }

      final double firstColumnIndex = (anchorXs.first / step).roundToDouble();
      final int columnCount =
          ((1.0 / step).ceil() - firstColumnIndex.toInt()).clamp(1, 7);

      final List<double> result = <double>[];
      for (int i = 0; i < columnCount; i++) {
        result.add((firstColumnIndex + i) * step);
        weekdayByIndex[i] = (i + 1).clamp(1, 7);
      }
      return (result, true);
    }

    // 情况 3：表头完全没认出来，按课程块聚类出列
    final List<double> cols = _clusterX(candidates);
    for (int i = 0; i < cols.length; i++) {
      weekdayByIndex[i] = (i + 1).clamp(1, 7);
    }
    return (cols, true);
  }

  /// 依据横向位置映射到列，再取该列的星期
  static int _weekdayByX(double x, List<double> columns, Map<int, int> map) {
    if (columns.isEmpty) return 1;
    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < columns.length; i++) {
      final double d = (columns[i] - x).abs();
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return map[bestIdx] ?? 1;
  }

  /// 依据纵向位置推断节次：找中心点最近的节次行
  static PeriodTime? _periodByY(double y, List<PeriodTime> periods,
      List<_TimeRow> rows) {
    if (periods.isEmpty || rows.isEmpty) return null;

    // 先把每行绑定到节次编号（顺序对应）
    final List<_TimeRow> sorted = List<_TimeRow>.from(rows)
      ..sort((_TimeRow a, _TimeRow b) => a.y.compareTo(b.y));
    final List<PeriodTime> sortedPeriods = List<PeriodTime>.from(periods)
      ..sort((PeriodTime a, PeriodTime b) => a.period.compareTo(b.period));

    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < sorted.length && i < sortedPeriods.length; i++) {
      final double d = (sorted[i].y - y).abs();
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    // 距离过远说明这一块根本不在课表主体里
    if (bestDist > 0.25) return null;
    return sortedPeriods[bestIdx];
  }

  /// 地点关键词
  static final RegExp _roomPattern = RegExp(
      r'([\u4e00-\u9fa5A-Za-z\d]{0,6}(?:教学楼|实验楼|综合楼|教\d*|楼|室|馆|校区|教室))');

  /// 从文字块中提取课程
  ///
  /// 两套判断并重：
  ///   1. 格子里写了「第N节 / 3-4节」→ 直接采用
  ///   2. 没写节次 → 按坐标把这块文字投射到时间轴上（节次由纵向位置决定），
  ///      星期由横向位置决定。这是真实课表最常见的版式。
  ///
  /// 从文字里提取周次范围
  ///
  /// 支持课表里常见的写法：
  ///   3-16周 / 7-8周 / 第3-16周 / 3~16周 / 3至16周
  ///   3-4,6-10周（多段取总范围）
  ///   3周（单周）
  ///   单周 / 双周 / 每周
  ///
  /// 返回 (起始周, 结束周, 类型)；类型为 all / odd / even。
  /// 识别不到时返回 null（由调用方决定兜底）。
  static (int, int, String)? extractWeekRange(String text) {
    // 先看有没有单双周字样
    String type = 'all';
    if (RegExp(r'单周').hasMatch(text)) {
      type = 'odd';
    } else if (RegExp(r'双周').hasMatch(text)) {
      type = 'even';
    }

    // 取出「周」字前的数字段
    final Match? m = RegExp(r'((?:\d{1,2}\s*[-—–~～至到]\s*\d{1,2}|\d{1,2})'
            r'(?:\s*[,，、]\s*(?:\d{1,2}\s*[-—–~～至到]\s*\d{1,2}|\d{1,2}))*)'
            r'\s*周')
        .firstMatch(text);

    if (m == null) {
      // 只写了单双周，没写具体周次：按整学期处理
      if (type != 'all') return (1, 16, type);
      return null;
    }

    final String seg = m.group(1)!;
    int? lo;
    int? hi;
    for (final RegExpMatch range
        in RegExp(r'(\d{1,2})\s*[-—–~～至到]\s*(\d{1,2})').allMatches(seg)) {
      final int a = int.parse(range.group(1)!);
      final int b = int.parse(range.group(2)!);
      if (a <= 0 || b <= 0 || a > 30 || b > 30) continue;
      final int s = a < b ? a : b;
      final int e = a < b ? b : a;
      lo = (lo == null || s < lo) ? s : lo;
      hi = (hi == null || e > hi) ? e : hi;
    }
    if (lo == null) {
      final List<int> singles = <int>[];
      for (final RegExpMatch one
          in RegExp(r'(\d{1,2})').allMatches(seg)) {
        final int n = int.parse(one.group(1)!);
        if (n > 0 && n <= 30) singles.add(n);
      }
      if (singles.isNotEmpty) {
        singles.sort();
        lo = singles.first;
        hi = singles.last;
      }
    }
    if (lo == null) {
      if (type != 'all') return (1, 16, type);
      return null;
    }
    return (lo, hi!, type);
  }

  /// 课程名里的噪声：这些碎片单独出现时不是课程
  static final RegExp _noiseWord = RegExp(
      r'^(连堂|上午|下午|晚上|[周星]\s*[期]?\s*[一二三四五六日天]|[一二三四五六日天]|'
      r'\d+\s*[号楼]|号楼|楼|周|第\d+周|校|室|全部.*|.*\d{1,2}:\d{2}.*)$');

  /// 判断一段文字像不像课程名
  static bool _looksLikeCourseName(String s) {
    final String t = s.trim();
    if (t.length < 2) return false;
    if (t.length > 24) return false; // 太长多半是把整行都抓进来了
    if (_noiseWord.hasMatch(t)) return false;
    if (_looksLikeTimeRow(t) && !_hasPeriod(t)) return false;
    if (RegExp(r'^\d+$').hasMatch(t)) return false;
    // 至少要有一个中文字符或字母
    return RegExp(r'[\u4e00-\u9fa5A-Za-z]').hasMatch(t);
  }

  /// 从一组碎片里挑出最像课程名的那个
  ///
  /// 规则：**按位置从上到下取第一个合格碎片**。
  /// 课表格子的版式基本固定——第一行是课名，下面是教师、周次、地点。
  ///
  /// 之前是「取最长的碎片」，结果选中了 `校本部综合大楼A202`（10 个字），
  /// 比真正的课名 `大学英语（1)_33` 还长，课名反而被丢掉。
  static String _pickCourseName(List<TextBlock> fragments) {
    final List<TextBlock> ordered = List<TextBlock>.from(fragments)
      ..sort((TextBlock a, TextBlock b) {
        final int byTop = a.top.compareTo(b.top);
        return byTop != 0 ? byTop : a.left.compareTo(b.left);
      });

    for (final TextBlock f in ordered) {
      final String cand = f.text
          .trim()
          .replaceAll(_periodWord, '')
          .replaceAll(_periodChineseWord, '')
          .replaceAll(RegExp(r'^[\s\-—,，、.。()（）\[\]0-9]+'), '')
          .replaceAll(RegExp(r'[\s\-—,，、.。()（）\[\]]+$'), '')
          .trim();
      if (_looksLikeCourseName(cand)) return cand;
    }
    return '';
  }

  /// 收集一组碎片里的地点
  static String _pickRoom(List<TextBlock> fragments) {
    for (final TextBlock f in fragments) {
      final Match? rm = _roomPattern.firstMatch(f.text);
      if (rm == null) continue;
      final String r = rm.group(1)!.trim();
      if (_looksLikeCourseName(r)) return r;
    }
    return '';
  }

  /// 返回 (课程列表, 是否有课程靠位置推断, 星期映射是否是推测的)
  static (List<Course>, bool, bool) parseCoursesWithFlags(
    List<TextBlock> blocks, {
    List<PeriodTime> periodTimes = const <PeriodTime>[],
  }) {
    final List<Course> courses = <Course>[];
    final List<_TimeRow> rows = _buildTimeRows(blocks);

    // 列检测：得到每列的横向中心与对应的星期
    final Map<int, int> weekdayByIndex = <int, int>{};
    final (List<double>, bool) colResult =
        _detectColumns(blocks, weekdayByIndex);
    final List<double> columns = colResult.$1;
    final bool weekdayGuessed = colResult.$2;

    bool inferred = false;

    // ---------- 第一步：把碎片按「格子」分组 ----------
    //
    // 关键认识：OCR 会把一个课程格子里的文字切成好几段
    // （例如「大学英语(1)_33 黄怡凡…」被切成「0全部…」「黄怡凡」「7-8周」）。
    // 之前把每段都当成一门课，导致导入一堆垃圾。
    // 这里先按「星期列 + 节次行」把碎片归到同一个格子，再合并成一门课。
    final Map<String, List<TextBlock>> cells = <String, List<TextBlock>>{};

    for (final TextBlock b in blocks) {
      final String text = b.text.trim();
      if (text.isEmpty || text.length < 2) continue;

      // 排除时间栏、星期表头、纯数字
      if (RegExp(r'^[周星]\s*[期]?\s*[一二三四五六日天]$').hasMatch(text)) {
        continue;
      }
      if (RegExp(r'^\d{1,2}[:：.]?\d{0,2}$').hasMatch(text)) continue;

      // 节次标签单独一行时（第1节 / 1-2节）也排除，它属于轴不属于格子
      final bool hasPeriodLabel = _hasPeriod(text);
      if (!hasPeriodLabel && _looksLikeTimeRow(text)) continue;

      // 判断这个碎片属于哪一列（星期）
      final int weekday = _weekdayByX(b.centerX, columns, weekdayByIndex);

      // 判断属于哪个节次行
      int period;
      final List<int> periods = _extractPeriods(text);
      if (periods.isNotEmpty) {
        period = periods.first;
      } else {
        final PeriodTime? pt = _periodByY(b.centerY, periodTimes, rows);
        if (pt == null) continue;
        period = pt.period;
        inferred = true;
      }

      final String key = '$weekday|$period';
      cells.putIfAbsent(key, () => <TextBlock>[]).add(b);
    }

    // ---------- 第二步：每个格子产出一门课 ----------
    int index = 0;
    for (final MapEntry<String, List<TextBlock>> entry in cells.entries) {
      final List<String> parts = entry.key.split('|');
      final int weekday = int.parse(parts[0]);
      final int period = int.parse(parts[1]);
      final List<TextBlock> fragments = entry.value;

      final String name = _pickCourseName(fragments);
      if (name.isEmpty) continue; // 全是噪声，这个格子没有课程

      // 节次范围：优先取碎片里明写的，其次看这个格子跨了几行
      int start = period;
      int end = period;
      for (final TextBlock f in fragments) {
        final List<int> ps = _extractPeriods(f.text);
        if (ps.isNotEmpty) {
          if (ps.first < start) start = ps.first;
          if (ps.last > end) end = ps.last;
        }
      }

      // 周次范围：课表里通常每格都标了（如「7-8周」「3-16周」）
      int startWeek = 1;
      int endWeek = 16;
      String weekType = 'all';
      for (final TextBlock f in fragments) {
        final (int, int, String)? wr = extractWeekRange(f.text);
        if (wr != null) {
          startWeek = wr.$1;
          endWeek = wr.$2;
          weekType = wr.$3;
          break;
        }
      }

      courses.add(Course(
        id: 'ocr_${DateTime.now().millisecondsSinceEpoch}_${index++}',
        name: name,
        weekday: weekday,
        startPeriod: start,
        endPeriod: end,
        room: _pickRoom(fragments),
        startWeek: startWeek,
        endWeek: endWeek,
        weekType: weekType,
      ));
    }

    courses.sort((Course a, Course b) {
      final int w = a.weekday.compareTo(b.weekday);
      return w != 0 ? w : a.startPeriod.compareTo(b.startPeriod);
    });
    return (courses, inferred, weekdayGuessed);
  }

  /// 兼容调用：只取课程列表
  static List<Course> parseCourses(
    List<TextBlock> blocks, {
    List<PeriodTime> periodTimes = const <PeriodTime>[],
  }) {
    return parseCoursesWithFlags(blocks, periodTimes: periodTimes).$1;
  }


  /// 统一入口
  static ParseResult parse(List<TextBlock> blocks) {
    final List<PeriodTime> periods = parsePeriodTimes(blocks);
    final (List<Course>, bool, bool) parsed =
        parseCoursesWithFlags(blocks, periodTimes: periods);
    final List<Course> courses = parsed.$1;
    final bool inferByPosition = parsed.$2;
    final bool weekdayGuessed = parsed.$3;
    final List<String> warnings = <String>[];

    if (periods.isEmpty) {
      warnings.add('未识别到课表边上的作息时间，请到设置页补充每节课的上课与下课时间，'
          '否则无法计算提醒时刻');
    } else {
      final Set<int> got = periods.map((PeriodTime p) => p.period).toSet();
      for (int i = 1; i <= periods.length; i++) {
        if (!got.contains(i)) {
          warnings.add('第 $i 节缺少时间，请核对');
        }
      }
    }

    if (courses.isEmpty) {
      warnings.add('未解析出课程，可展开「识别到的原始文字」对照，或手动录入');
    } else {
      if (inferByPosition) {
        warnings.add('部分课程格子里没写节次，已按位置推断所在节次，请重点核对节次');
      }
      if (weekdayGuessed) {
        warnings.add('星期表头没认全，已按列的顺序从左到右对应周一起，'
            '请重点核对每门课的星期');
      }
    }

    return ParseResult(
      periodTimes: periods,
      courses: courses,
      warnings: warnings,
    );
  }
}

/// 时间轴上的一行
class _TimeRow {
  final double top;
  final double bottom;
  final double y;
  final int? startMinute;
  final int? endMinute;

  const _TimeRow({
    required this.top,
    required this.bottom,
    required this.y,
    this.startMinute,
    this.endMinute,
  });
}

/// 星期表头锚点
class _WeekdayAnchor {
  final int weekday;
  final double x;

  const _WeekdayAnchor({required this.weekday, required this.x});
}

/// 默认作息模板：识别不到时间栏时一键套用
List<PeriodTime> defaultPeriodTimes() => <PeriodTime>[
      const PeriodTime(period: 1, startMinute: 8 * 60, endMinute: 8 * 60 + 45),
      const PeriodTime(
          period: 2, startMinute: 8 * 60 + 55, endMinute: 9 * 60 + 40),
      const PeriodTime(
          period: 3, startMinute: 10 * 60, endMinute: 10 * 60 + 45),
      const PeriodTime(
          period: 4, startMinute: 10 * 60 + 55, endMinute: 11 * 60 + 40),
      const PeriodTime(
          period: 5, startMinute: 14 * 60, endMinute: 14 * 60 + 45),
      const PeriodTime(
          period: 6, startMinute: 14 * 60 + 55, endMinute: 15 * 60 + 40),
      const PeriodTime(
          period: 7, startMinute: 16 * 60, endMinute: 16 * 60 + 45),
      const PeriodTime(
          period: 8, startMinute: 18 * 60 + 30, endMinute: 19 * 60 + 15),
      const PeriodTime(
          period: 9, startMinute: 19 * 60 + 25, endMinute: 20 * 60 + 10),
      const PeriodTime(
          period: 10, startMinute: 20 * 60 + 20, endMinute: 21 * 60 + 5),
    ];
