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
      courses = _list(data['courses']).map(Course.fromMap).toList();
      periodTimes = _list(data['periods']).map(PeriodTime.fromMap).toList();
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
    courses = _list(data['courses']).map(Course.fromMap).toList();
    periodTimes = _list(data['periods']).map(PeriodTime.fromMap).toList();
    alarms = _list(data['alarms']).map(Alarm.fromMap).toList();
    logs = <SmsLog>[];
    save();
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
