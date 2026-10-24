// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 本地存储：JSON 文档存储（课程 / 作息时间 / 闹钟 / 短信日志）+ 应用设置
//
// 设计说明：
// - 数据量很小（一学期课表 + 若干闹钟），使用「内存 + JSON 文件」存储，
//   不依赖任何原生数据库库，手机与电脑两端行为完全一致。
// - 每次变更后异步落盘，写入时先写临时文件再替换，避免掉电损坏。
// - 备份文件就是同一份 JSON，导出导入天然可用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/models.dart';
import '../model/period_time.dart';

class Storage {
  Storage._();

  static final Storage instance = Storage._();

  File? _file;
  bool _loaded = false;

  /// 落盘串行化，避免并发写导致文件错乱
  Future<void> _writeChain = Future<void>.value();

  List<Course> courses = <Course>[];
  List<PeriodTime> periodTimes = <PeriodTime>[];
  List<Alarm> alarms = <Alarm>[];
  List<SmsLog> logs = <SmsLog>[];

  /// 初始化数据文件位置；[overridePath] 供测试指定临时文件
  Future<void> init({String? overridePath}) async {
    if (_loaded) return;
    String path;
    if (overridePath != null) {
      path = overridePath;
    } else {
      final Directory dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      path = p.join(dir.path, 'timetable_data.json');
    }
    _file = File(path);
    await _read();
    _loaded = true;
  }

  Future<void> _read() async {
    final File? f = _file;
    if (f == null || !await f.exists()) return;
    try {
      final String raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final Map<String, Object?> data =
          Map<String, Object?>.from(jsonDecode(raw) as Map);
      // 加载时也做清洗：存档可能是旧版本写的、也可能被手工改过。
      // 只清洗导入入口的话，老用户升级后坏数据会一直跟着。
      courses = _parseCourses(_list(data['courses']));
      periodTimes = _parsePeriods(_list(data['periods']));
      alarms = _list(data['alarms']).map(Alarm.fromMap).toList();
      logs = _list(data['logs']).map(SmsLog.fromMap).toList();
    } catch (_) {
      // 数据损坏时不阻塞启动：保留空数据，用户可以重新导入备份
      courses = <Course>[];
      periodTimes = <PeriodTime>[];
      alarms = <Alarm>[];
      logs = <SmsLog>[];
    }
  }

  static List<Map<String, Object?>> _list(Object? value) {
    if (value is! List) return <Map<String, Object?>>[];
    return value
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> e) => Map<String, Object?>.from(e))
        .toList();
  }

  /// 作息时间统一入口：夹范围 + 去重 + 排序。
  ///
  /// startMinute 越界（如手写成 1500）时，App 算出的上课前提醒时刻
  /// 会超过 24 小时，原生侧 nextTrigger 直接拒绝注册 ——
  /// 表现为「这门课一条提醒都没有」，同样是静默失效。
  static List<PeriodTime> _parsePeriods(List<Map<String, Object?>> raw) {
    final List<PeriodTime> out = <PeriodTime>[];
    final Set<int> seen = <int>{};
    for (final Map<String, Object?> m in raw) {
      final PeriodTime pt = PeriodTime.fromMap(m);
      if (pt.period < 1 || pt.period > 20) continue;
      if (seen.contains(pt.period)) continue;   // 重复节次只保留第一个
      seen.add(pt.period);

      int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
      int s = clamp(pt.startMinute, 0, 1439);
      int e = clamp(pt.endMinute, 0, 1439);
      if (e <= s) {
        // 颠倒/相等时兜底 45 分钟。注意 s 可能已在 1439 上限，
        // 直接 +45 会再次越界，所以先夹再回退。
        e = clamp(s + 45, 0, 1439);
        if (e <= s) s = clamp(e - 45, 0, 1439);
      }

      out.add(PeriodTime(period: pt.period, startMinute: s, endMinute: e));
    }
    out.sort((PeriodTime a, PeriodTime b) => a.period.compareTo(b.period));
    return out;
  }

  /// 课程列表统一入口：清洗 + 保证 id 唯一。
  ///
  /// 【为什么加载和导入都必须走这里】
  ///   - weekday: 14      -> 课表网格只有 1..7，这门课渲染不出来
  ///   - startPeriod: 99  -> 查不到作息时间，闹钟连一条都不会生成
  ///   - id 缺失/重复     -> 闹钟 id 变成 pre_ / post_ 全撞车，
  ///                         所有课程只剩最后一条提醒
  /// 这三种坏数据都不报错，只会让功能「静默失效」。
  /// 存档可能来自旧版本或手工编辑，所以启动加载时也必须清洗，
  /// 不能只在导入时洗一次。
  static List<Course> _parseCourses(List<Map<String, Object?>> raw) {
    final Set<String> usedIds = <String>{};
    final List<Course> cleaned = <Course>[];
    int seq = 0;
    for (final Map<String, Object?> m in raw) {
      final Course? c = _sanitizeCourse(Course.fromMap(m));
      if (c == null) continue;

      String id = c.id;
      if (id.isEmpty || usedIds.contains(id)) {
        id = 'c_${DateTime.now().microsecondsSinceEpoch}_${seq++}';
      }
      usedIds.add(id);
      cleaned.add(id == c.id ? c : c.copyWith(id: id));
    }
    return cleaned;
  }

  /// 导出为 JSON 字符串（备份 / 手机电脑同步共用）
  String exportJson({bool pretty = true}) {
    final Map<String, Object?> data = <String, Object?>{
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'courses': courses.map((Course c) => c.toMap()).toList(),
      'periods': periodTimes.map((PeriodTime t) => t.toMap()).toList(),
      'alarms': alarms.map((Alarm a) => a.toMap()).toList(),
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : jsonEncode(data);
  }

  /// 从 JSON 字符串导入（覆盖现有数据）
  void importJson(String content) {
    final Map<String, Object?> data =
        Map<String, Object?>.from(jsonDecode(content) as Map);

    // 与启动加载共用同一套清洗（见 _parseCourses / _parsePeriods 的注释）。
    courses = _parseCourses(_list(data['courses']));
    periodTimes = _parsePeriods(_list(data['periods']));
    alarms = _list(data['alarms']).map(Alarm.fromMap).toList();
    logs = <SmsLog>[];
    save();
  }

  /// 把课程数据夹到合法范围；没有课名的直接丢掉（返回 null）
  ///
  /// 注意 id 不在这里生成 —— 唯一性统一在 _parseCourses 里处理，
  /// 因为这里看不到其它课程。
  static Course? _sanitizeCourse(Course c) {
    final String name = c.name.trim();
    if (name.isEmpty) return null;

    int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

    // 星期：1..7
    final int weekday = clamp(c.weekday, 1, 7);
    // 节次：1..20（一般 12 节，留点余量）
    int sp = clamp(c.startPeriod, 1, 20);
    int ep = clamp(c.endPeriod, 1, 20);
    if (ep < sp) {
      final int t = sp;
      sp = ep;
      ep = t;
    }
    // 周次：1..30
    int sw = clamp(c.startWeek, 1, 30);
    int ew = clamp(c.endWeek, 1, 30);
    if (ew < sw) {
      final int t = sw;
      sw = ew;
      ew = t;
    }
    // 单双周只认这三个值
    final String wt = <String>{'all', 'odd', 'even'}.contains(c.weekType)
        ? c.weekType
        : 'all';

    return c.copyWith(
      name: name,
      weekday: weekday,
      startPeriod: sp,
      endPeriod: ep,
      startWeek: sw,
      endWeek: ew,
      weekType: wt,
    );
  }

  /// 异步落盘
  void save() {
    final File? f = _file;
    if (f == null) return;
    _writeChain = _writeChain.then((_) async {
      try {
        final String content = exportJson(pretty: false);
        final File tmp = File('${f.path}.tmp');
        await tmp.writeAsString(content, flush: true);
        if (await tmp.exists()) {
          if (await f.exists()) await f.delete();
          await tmp.rename(f.path);
        }
      } catch (_) {
        // 落盘失败不影响内存中的使用，下次变更会再次尝试
      }
    });
  }

  /// 等待所有落盘完成（退出或测试时使用）
  Future<void> flush() => _writeChain;

  /// 数据文件路径
  String? get path => _file?.path;
}

/// 设置存储（SharedPreferences，跨平台可用）
class SettingsStore {
  static const String _kSettings = 'app_settings';

  static Future<AppSettings> load() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kSettings);
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      return AppSettings.fromJson(
          Map<String, Object?>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings settings) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kSettings, jsonEncode(settings.toJson()));
  }
}
