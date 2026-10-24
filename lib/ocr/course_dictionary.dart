// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 课表词典：用「已经确认过的课表」去纠正 OCR 结果
//
// 思路（这就是把准确的路用来提升方便的路）：
//   1. 用户先用「粘贴导入」（100% 准确）建立课表
//   2. 这份课表里的课程名 / 教师 / 教室就成了一部**个人词典**
//   3. 以后用截图 OCR 时，认出来的碎片先跟词典模糊匹配：
//        「人工智」      → 人工智能与信息技术基础A_05
//        「崔昕昕，」    → 崔昕昕
//   4. 匹配上的自动修正并记录，匹配不上的标记为「待核对」
//
// 为什么不直接「猜」：
//   OCR 错字有随机性，凭空纠正等于编造。但**同一学期课表是固定的**，
//   所以「跟已知课表比对」是有依据的推断，而不是猜。

/// 编辑距离（Levenshtein），用于模糊匹配
int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  final List<int> prev = List<int>.generate(b.length + 1, (int i) => i);
  final List<int> cur = List<int>.filled(b.length + 1, 0);

  for (int i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (int j = 1; j <= b.length; j++) {
      final int cost = a[i - 1] == b[j - 1] ? 0 : 1;
      final int del = prev[j] + 1;
      final int ins = cur[j - 1] + 1;
      final int sub = prev[j - 1] + cost;
      int m = del < ins ? del : ins;
      if (sub < m) m = sub;
      cur[j] = m;
    }
    prev.setAll(0, cur);
  }
  return prev[b.length];
}

/// 相似度 0..1（1 = 完全相同）
double similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  // 一方包含另一方时，按长度比例算（「人工智」是「人工智能…」的前缀）
  if (b.contains(a) || a.contains(b)) {
    final int shorter = a.length < b.length ? a.length : b.length;
    final int longer = a.length > b.length ? a.length : b.length;
    return 0.6 + 0.4 * (shorter / longer);
  }
  final int d = editDistance(a, b);
  final int m = a.length > b.length ? a.length : b.length;
  return 1 - d / m;
}

/// 匹配结果
class MatchResult {
  final String value;
  final double score;

  const MatchResult(this.value, this.score);
}

/// 个人课表词典
///
/// 相似度阈值可调：不同学校课名差异大（简称「高数」vs 全称
/// 「高等数学A(1)」），一刀切的阈值会一边误纠正、一边纠正不动。
/// 阈值越高越保守（宁可不动），越低越激进（可能改错）。
class CourseDictionary {
  final List<String> names;
  final List<String> teachers;
  final List<String> rooms;

  /// 课名匹配阈值
  final double nameThreshold;

  /// 教师匹配阈值
  final double teacherThreshold;

  /// 地点匹配阈值（地点格式固定，默认更严格，
  /// 避免把 A202 改成 B202 这种「差一位」的误纠正）
  final double roomThreshold;

  const CourseDictionary({
    this.names = const <String>[],
    this.teachers = const <String>[],
    this.rooms = const <String>[],
    this.nameThreshold = 0.55,
    this.teacherThreshold = 0.6,
    this.roomThreshold = 0.7,
  });

  bool get isEmpty => names.isEmpty && teachers.isEmpty && rooms.isEmpty;

  /// 从课程列表构建词典
  static CourseDictionary fromCourses(
    Iterable<Object?> courses, {
    double nameThreshold = 0.55,
    double teacherThreshold = 0.6,
    double roomThreshold = 0.7,
  }) {
    final Set<String> names = <String>{};
    final Set<String> teachers = <String>{};
    final Set<String> rooms = <String>{};
    for (final Object? c in courses) {
      if (c == null) continue;
      try {
        final dynamic d = c;
        final String n = (d.name as String?) ?? '';
        final String t = (d.teacher as String?) ?? '';
        final String r = (d.room as String?) ?? '';
        if (n.trim().isNotEmpty) names.add(n.trim());
        if (t.trim().isNotEmpty) teachers.add(t.trim());
        if (r.trim().isNotEmpty) rooms.add(r.trim());
      } catch (_) {
        // 忽略类型不符的条目
      }
    }
    return CourseDictionary(
      names: names.toList(),
      teachers: teachers.toList(),
      rooms: rooms.toList(),
      nameThreshold: nameThreshold,
      teacherThreshold: teacherThreshold,
      roomThreshold: roomThreshold,
    );
  }

  /// 在候选集合里找最相似的一项
  static MatchResult? bestMatch(
    String fragment,
    List<String> candidates, {
    double minScore = 0.55,
    int minLength = 2,
  }) {
    final String q = fragment.trim();
    if (q.length < minLength || candidates.isEmpty) return null;

    // 完全相同直接返回
    for (final String c in candidates) {
      if (c == q) return MatchResult(c, 1.0);
    }

    MatchResult? best;
    for (final String c in candidates) {
      final double s = similarity(q, c);
      if (best == null || s > best.score) {
        best = MatchResult(c, s);
      }
    }
    if (best != null && best.score >= minScore) return best;
    return null;
  }

  MatchResult? matchName(String fragment) =>
      bestMatch(fragment, names, minScore: nameThreshold);

  MatchResult? matchTeacher(String fragment) =>
      bestMatch(fragment, teachers, minScore: teacherThreshold);

  MatchResult? matchRoom(String fragment) =>
      bestMatch(fragment, rooms, minScore: roomThreshold);

  /// 复制并调整阈值（供设置页/调试用）
  CourseDictionary withThresholds({
    double? name,
    double? teacher,
    double? room,
  }) {
    return CourseDictionary(
      names: names,
      teachers: teachers,
      rooms: rooms,
      nameThreshold: name ?? nameThreshold,
      teacherThreshold: teacher ?? teacherThreshold,
      roomThreshold: room ?? roomThreshold,
    );
  }
}

/// 一次纠正的记录（用于界面提示「已按词典修正」）
class Correction {
  final String field;   // name / teacher / room
  final String from;
  final String to;
  final double score;

  const Correction(this.field, this.from, this.to, this.score);

  @override
  String toString() => '$field: 「$from」→「$to」(${(score * 100).round()}%)';
}

/// 用词典纠正一组解析结果
class DictionaryCorrector {
  final CourseDictionary dict;

  const DictionaryCorrector(this.dict);

  /// 纠正课名/教师/地点，返回 (纠正后的三元组, 纠正记录)
  ({String name, String teacher, String room, List<Correction> fixes}) correct({
    required String name,
    required String teacher,
    required String room,
  }) {
    final List<Correction> fixes = <Correction>[];
    String n = name;
    String t = teacher;
    String r = room;

    if (n.isNotEmpty) {
      final MatchResult? m = dict.matchName(n);
      if (m != null && m.value != n) {
        fixes.add(Correction('name', n, m.value, m.score));
        n = m.value;
      }
    }
    if (t.isNotEmpty) {
      final MatchResult? m = dict.matchTeacher(t);
      if (m != null && m.value != t) {
        fixes.add(Correction('teacher', t, m.value, m.score));
        t = m.value;
      }
    }
    if (r.isNotEmpty) {
      final MatchResult? m = dict.matchRoom(r);
      if (m != null && m.value != r) {
        fixes.add(Correction('room', r, m.value, m.score));
        r = m.value;
      }
    }
    return (name: n, teacher: t, room: r, fixes: fixes);
  }
}
