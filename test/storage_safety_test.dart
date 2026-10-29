// 存储安全性测试：保存过程中断也不能丢数据
//
// 真实风险：早先保存是「写 tmp → 删正式文件 → tmp 改名」，
// 删完到改名之间进程被杀，正式文件就没了，而启动只读正式文件 ——
// 课表和闹钟数据全部丢失。现在保存不再先删，并把 .bak / .tmp 作为
// 启动时的恢复来源。这里用真实临时目录验证恢复路径。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/model/models.dart';
import 'package:timetable_app/model/period_time.dart';
import 'package:timetable_app/services/storage.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tt_storage');
    path = '${dir.path}${Platform.pathSeparator}timetable_data.json';
    // Storage 是单例，每个用例都要重置，才能真的重新读盘
    Storage.instance.debugResetForTest();
  });

  tearDown(() async {
    Storage.instance.debugResetForTest();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  /// 先正常存一份数据到 [target] 路径
  Future<void> saveSample(String target) async {
    final Storage s = Storage.instance;
    await s.init(overridePath: target);
    s.courses = <Course>[
      const Course(
        id: 'c1',
        name: '高等数学A(1)_04',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        room: '3号教学楼3-310',
        teacher: '张怡通*',
        startWeek: 3,
        endWeek: 16,
      ),
    ];
    s.periodTimes = <PeriodTime>[
      const PeriodTime(period: 1, startMinute: 8 * 60, endMinute: 8 * 60 + 45),
    ];
    s.save();
    await s.flush();
  }

  test('正常保存后能读回', () async {
    await saveSample(path);
    Storage.instance.debugResetForTest();

    final Storage s = Storage.instance;
    await s.init(overridePath: path);
    expect(s.courses, hasLength(1));
    expect(s.courses.first.name, contains('高等数学'));
    expect(s.periodTimes, hasLength(1));
  });

  test('正式文件丢失、只剩 .bak 时能恢复', () async {
    await saveSample(path);
    Storage.instance.debugResetForTest();

    // 模拟「正式文件已改名为 .bak，但 tmp 还没转正」时进程被杀
    final File main = File(path);
    expect(await main.exists(), isTrue);
    await main.rename('$path.bak');
    expect(await main.exists(), isFalse);

    final Storage s = Storage.instance;
    await s.init(overridePath: path);

    expect(s.courses, hasLength(1), reason: '应该从 .bak 恢复出课程');
    expect(s.courses.first.name, contains('高等数学'));
    // 恢复后要写回正式文件，否则下次启动还得再恢复一遍
    expect(await File(path).exists(), isTrue);
  });

  test('只剩 .tmp 时能恢复', () async {
    await saveSample(path);
    Storage.instance.debugResetForTest();

    // 模拟「内容已写进 tmp，正式文件还没换过去」
    await File(path).rename('$path.tmp');
    expect(await File(path).exists(), isFalse);

    final Storage s = Storage.instance;
    await s.init(overridePath: path);
    expect(s.courses, hasLength(1), reason: '应该从 .tmp 恢复出课程');
  });

  test('正式文件完好时不读 .bak（避免拿到旧数据）', () async {
    await saveSample(path);
    Storage.instance.debugResetForTest();

    // 放一份「旧」备份在旁边
    await File(path).copy('$path.bak');

    final Storage s = Storage.instance;
    await s.init(overridePath: path);
    expect(s.courses, hasLength(1));
    expect(s.courses.first.name, contains('高等数学'));
  });
}
