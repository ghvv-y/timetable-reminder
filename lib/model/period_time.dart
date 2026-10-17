// 纯数据模型：作息时间
//
// 单独成文件是为了让「课表解析」等纯逻辑模块不依赖数据库与服务层，
// 这样单元测试可以在没有原生 SQLite 的环境下直接运行。

/// 把任意 Map 的 value 统一转成 int
int intFrom(Object? value, int fallback) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? fallback;
}

/// 把任意 Map 的 value 统一转成 String
String stringFrom(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

/// 作息时间：第 period 节的上课 / 下课时间（从课表边上标注的时间栏识别而来）
class PeriodTime {
  /// 节次，从 1 开始
  final int period;

  /// 上课时间（当天分钟数）
  final int startMinute;

  /// 下课时间（当天分钟数）
  final int endMinute;

  const PeriodTime({
    required this.period,
    required this.startMinute,
    required this.endMinute,
  });

  factory PeriodTime.fromMap(Map<String, Object?> m) => PeriodTime(
        period: intFrom(m['period'], 1),
        startMinute: intFrom(m['startMinute'], 0),
        endMinute: intFrom(m['endMinute'], 0),
      );

  /// 转为可直接写入数据库的 Map（不含自定义类型）
  Map<String, Object?> toMap() => <String, Object?>{
        'period': period,
        'startMinute': startMinute,
        'endMinute': endMinute,
      };

  PeriodTime copyWith({int? startMinute, int? endMinute}) => PeriodTime(
        period: period,
        startMinute: startMinute ?? this.startMinute,
        endMinute: endMinute ?? this.endMinute,
      );
}
