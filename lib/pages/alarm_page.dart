// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 闹钟页：统一管理课表自动提醒与自定义闹钟
//
// 规则：
// - 「备注」就是短信正文，到点原样发送。
// - 到点完全静默：不响铃、不震动、不弹通知。
//
// 页面提供：
// - 底部「添加闹钟」按钮：随时新增自定义闹钟
// - 底部 / 右上「批量删除」按钮：多选后一次删除多条

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/models.dart';
import '../services/alarm_scheduler.dart';
import '../services/app_state.dart';
import '../utils/time_utils.dart';
import '../utils/validators.dart';

class AlarmPage extends StatefulWidget {
  const AlarmPage({super.key});

  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  /// 是否处于批量选择模式
  bool _selectMode = false;

  /// 已勾选的闹钟 id
  final Set<String> _selected = <String>{};

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  Future<void> _deleteSelected(AppState state) async {
    if (_selected.isEmpty) return;
    final int count = _selected.length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认批量删除'),
        content: Text('将删除选中的 $count 条闹钟。\n'
            '课表自动提醒删掉后，可点右上角刷新按钮重新生成。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final int removed = await state.deleteAlarms(_selected.toList());
    if (!mounted) return;
    _exitSelectMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $removed 条闹钟')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    return Column(
      children: <Widget>[
        _header(context, state),
        Expanded(
          child: state.alarms.isEmpty
              ? _empty(context, state)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: <Widget>[
                    if (state.courseAlarms.isNotEmpty) ...<Widget>[
                      const _SectionTitle('课表自动提醒（上课 / 下课）'),
                      for (final Alarm a in state.courseAlarms)
                        _alarmTile(context, state, a),
                    ],
                    if (state.customAlarms.isNotEmpty) ...<Widget>[
                      const _SectionTitle('自定义闹钟'),
                      for (final Alarm a in state.customAlarms)
                        _alarmTile(context, state, a),
                    ],
                  ],
                ),
        ),
        _bottomBar(context, state),
      ],
    );
  }

  /// 顶部标题与操作
  Widget _header(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      child: Row(
        children: <Widget>[
          const Text('闹钟',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (_selectMode)
            Text('已选 ${_selected.length} 条',
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF2F6BFF)))
          else
            Text(
              '共 ${state.alarms.length} 条 · 启用 ${state.alarms.where((Alarm a) => a.enabled).length} 条',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          const Spacer(),
          if (_selectMode) ...<Widget>[
            TextButton(
              onPressed: _selected.length == state.alarms.length
                  ? () => setState(() => _selected.clear())
                  : () => setState(() {
                        _selected
                          ..clear()
                          ..addAll(state.alarms.map((Alarm a) => a.id));
                      }),
              child: Text(
                  _selected.length == state.alarms.length ? '取消全选' : '全选'),
            ),
            IconButton(
              tooltip: '退出批量删除',
              onPressed: _exitSelectMode,
              icon: const Icon(Icons.close),
            ),
          ] else ...<Widget>[
            IconButton(
              tooltip: '撤销删除',
              onPressed:
                  state.lastDeleted == null ? null : () => state.undoDelete(),
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: '由课表重新生成提醒',
              onPressed: () async {
                await state.regenerateCourseAlarms();
                if (context.mounted) {
                  _toast(context, '已按课表重新生成上下课提醒');
                }
              },
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '闹钟诊断日志（没收到短信时看这个）',
              onPressed: _showAlarmDiagnostics,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部操作栏：新增闹钟 / 批量删除
  Widget _bottomBar(BuildContext context, AppState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEDEFF3))),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _showEditSheet(context, state, null),
              icon: const Icon(Icons.add_alarm, size: 18),
              label: const Text('添加闹钟'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _selectMode
                ? FilledButton.icon(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _deleteSelected(state),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD9534F),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.delete_forever, size: 18),
                    label: Text(_selected.isEmpty
                        ? '删除(0)'
                        : '删除(${_selected.length})'),
                  )
                : OutlinedButton.icon(
                    onPressed: state.alarms.isEmpty
                        ? null
                        : () => setState(() => _selectMode = true),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('批量删除'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, AppState state) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('还没有任何闹钟',
                style: TextStyle(fontSize: 15, color: Color(0xFF666666))),
            const SizedBox(height: 6),
            const Text('点下方「添加闹钟」自己加，也可按课表自动生成上下课提醒',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                await state.regenerateCourseAlarms();
                if (context.mounted) _toast(context, '已按课表生成提醒');
              },
              child: const Text('由课表生成上下课提醒'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _alarmTile(BuildContext context, AppState state, Alarm a) {
    final bool selected = _selected.contains(a.id);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: _selectMode && selected ? const Color(0xFFE8EFFF) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _selectMode && selected
              ? const Color(0xFF2F6BFF)
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: ListTile(
        onTap: () {
          if (_selectMode) {
            setState(() {
              if (selected) {
                _selected.remove(a.id);
              } else {
                _selected.add(a.id);
              }
            });
            return;
          }
          _showEditSheet(context, state, a);
        },
        onLongPress: () {
          setState(() {
            _selectMode = true;
            _selected.add(a.id);
          });
        },
        leading: _selectMode
            ? Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                color: const Color(0xFF2F6BFF),
              )
            : null,
        title: Row(
          children: <Widget>[
            Text(fmtMinute(a.timeMinute),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F4FA),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _repeatText(a),
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFF44506B)),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: a.courseId == null
                    ? const Color(0xFFF3F0FF)
                    : const Color(0xFFEAF4FF),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                a.label,
                style: const TextStyle(fontSize: 11, color: Color(0xFF5A5A8B)),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            a.message.isEmpty ? '（备注为空，不会发送）' : a.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555)),
          ),
        ),
        trailing: _selectMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Switch(
                    value: a.enabled,
                    onChanged: (bool v) => state.setAlarmEnabled(a.id, v),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: () async {
                      await state.deleteAlarm(a.id);
                      if (context.mounted) _toast(context, '已删除，可点撤销恢复');
                    },
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
      ),
    );
  }

  String _repeatText(Alarm a) {
    switch (a.repeatType) {
      case 'daily':
        return '每天';
      case 'weekly':
        if (a.courseId != null && a.weekday != null) {
          return weekdayName(a.weekday!);
        }
        if (a.weekdays.isEmpty) return '按星期';
        return a.weekdays.map((int d) => weekdayName(d)).join(' ');
      default:
        return '仅一次';
    }
  }

  /// 编辑 / 新增闹钟
  void _showEditSheet(BuildContext context, AppState state, Alarm? origin) {
    final TextEditingController msgCtl =
        TextEditingController(text: origin?.message ?? '');
    TimeOfDay time = origin == null
        ? const TimeOfDay(hour: 9, minute: 0)
        : TimeOfDay(
            hour: origin.timeMinute ~/ 60, minute: origin.timeMinute % 60);
    String repeatType = origin?.repeatType ?? 'once';
    final Set<int> weekdays = <int>{...?origin?.weekdays};

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setLocal) {
            final bool readOnlyCourse = origin?.courseId != null;
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(origin == null ? '添加闹钟' : '编辑闹钟',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        const Text('发送时间　'),
                        OutlinedButton(
                          onPressed: () async {
                            final TimeOfDay? picked = await showTimePicker(
                              context: ctx,
                              initialTime: time,
                            );
                            if (picked != null) setLocal(() => time = picked);
                          },
                          child: Text(
                            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: msgCtl,
                      maxLines: 4,
                      minLines: 2,
                      decoration: const InputDecoration(
                        labelText: '备注（就是短信正文，原样发送）',
                        border: OutlineInputBorder(),
                        hintText: '例如：数据结构 10:00 教三301 带上实验报告',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('重复', style: TextStyle(fontSize: 13)),
                    Wrap(
                      spacing: 6,
                      children: <Widget>[
                        ChoiceChip(
                          label: const Text('仅一次'),
                          selected: repeatType == 'once',
                          onSelected: (_) =>
                              setLocal(() => repeatType = 'once'),
                        ),
                        ChoiceChip(
                          label: const Text('每天'),
                          selected: repeatType == 'daily',
                          onSelected: (_) =>
                              setLocal(() => repeatType = 'daily'),
                        ),
                        ChoiceChip(
                          label: const Text('按星期'),
                          selected: repeatType == 'weekly',
                          onSelected: (_) =>
                              setLocal(() => repeatType = 'weekly'),
                        ),
                      ],
                    ),
                    if (repeatType == 'weekly' &&
                        origin?.courseId == null) ...<Widget>[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: <Widget>[
                          for (int d = 1; d <= 7; d++)
                            FilterChip(
                              label: Text(weekdayName(d)),
                              selected: weekdays.contains(d),
                              onSelected: (bool v) => setLocal(() {
                                if (v) {
                                  weekdays.add(d);
                                } else {
                                  weekdays.remove(d);
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F7FB),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '到点后：手机不响铃、不震动、不弹通知，只把上面的备注原样作为短信发出，由手表完成提醒。',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        if (origin != null)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await state.deleteAlarm(origin.id);
                                if (context.mounted) {
                                  _toast(context, '已删除，可点撤销恢复');
                                }
                              },
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const Text('删除'),
                            ),
                          ),
                        if (origin != null) const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              // 按星期的闹钟必须至少选一天，否则永远算不出
                              // 触发时刻 —— 界面看着是启用的，到点却一声不响。
                              if (!isValidAlarmWeekdays(
                                  repeatType, weekdays.toList())) {
                                _toast(context, '请至少选择一个星期，否则这个闹钟永远不会响');
                                return;
                              }
                              final int minute = time.hour * 60 + time.minute;
                              final Alarm value = Alarm(
                                id: origin?.id ??
                                    'own_${DateTime.now().microsecondsSinceEpoch}',
                                timeMinute: minute,
                                message: msgCtl.text,
                                repeatType: readOnlyCourse
                                    ? (origin?.repeatType ?? 'weekly')
                                    : repeatType,
                                weekdays: readOnlyCourse
                                    ? (origin?.weekdays ?? <int>[])
                                    : weekdays.toList(),
                                enabled: origin?.enabled ?? true,
                                label: origin?.label ?? AlarmLabel.custom,
                                courseId: origin?.courseId,
                                weekday: origin?.weekday,
                              );
                              Navigator.pop(ctx);
                              await state.upsertAlarm(value);
                            },
                            child: const Text('保存'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (origin != null)
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: () async {
                            final String result = await state.sendNow(origin);
                            if (context.mounted) {
                              _toast(context,
                                  result == 'success' ? '已发送' : '发送失败');
                            }
                          },
                          icon: const Icon(Icons.send_outlined, size: 18),
                          label: const Text('立即发送这条短信（测试用）'),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 闹钟诊断日志
  ///
  /// 「到点了没收到短信」这种情况，光看界面判断不出来：
  /// 可能是没注册、号码为空、没权限、或系统拦截。
  /// 这里把原生侧记录的每一步显示出来，一看就知道卡在哪。
  Future<void> _showAlarmDiagnostics() async {
    final String log = await AlarmScheduler.readDiagnostics();
    final String? lastFail = await AlarmScheduler.lastSmsFailure();
    final AlarmHealth health = await AlarmScheduler.health();
    if (!mounted) return;

    // 只显示和闹钟有关的行，避免截屏日志干扰
    final List<String> lines = log
        .split('\n')
        .where((String l) =>
            l.contains('闹钟') ||
            l.contains('注册') ||
            l.contains('发送') ||
            l.contains('短信') ||
            l.contains('号码') ||
            l.contains('卡') ||
            l.contains('周'))
        .toList();

    final String shown =
        lines.isEmpty ? '（还没有闹钟相关记录）' : lines.join('\n');

    String fmtTs(int ms) {
      if (ms <= 0) return '无';
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${t.month}-${t.day} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    }

    final List<String> problems = <String>[];
    if (health.looksCleared) {
      problems.add('系统里的闹钟已被清空（配置 ${health.configured} 条，'
          '系统里 0 条）。这是国产系统冻结「长期没打开」的应用导致的 —— '
          '请点下面「重新激活闹钟」，并到系统设置里允许「自启动」和「后台运行」。');
    }
    if (!health.notifEnabled && health.wantsNotify) {
      // Android 13+ 通知权限被拒时 notify() 是静默失败：
      // 不报错、不显示、日志里也看不出异常，用户只会觉得「闹钟没响」。
      problems.add('通知权限被关闭了。当前提醒方式包含通知，'
          '但系统不会显示任何提醒（而且不会报错）。'
          '请到 系统设置 → 通知 → 课表提醒 → 允许通知。');
    }
    if (!health.weekKnown) {
      problems.add('还没设置「学期开始日」，所以起止周/单双周过滤不生效，'
          '已上完的课仍会提醒。去设置页填一下学期开始日。');
    }
    // 下面三项是「闹钟注册了但到点没动静」的常见原因。
    // 尤其电池优化：国产 ROM 冻结应用后，系统连闹钟都不投递，
    // 日志里连「闹钟触发」都不会出现 —— 只能靠这里提示用户去放行。
    if (!health.batteryUnrestricted) {
      problems.add('电池优化没有放行。系统可能冻结本应用，'
          '冻结后闹钟**完全不会响**（日志里连「闹钟触发」都没有）。'
          '请到 系统设置 → 电池/耗电管理 → 课表提醒 → 允许后台高耗电 / 不限制。');
    }
    if (!health.exactAlarmAllowed) {
      problems.add('没有「精确闹钟」权限。提醒仍会响，但可能晚几分钟。'
          '请到 系统设置 → 应用 → 特殊权限 → 闹钟和提醒 → 允许课表提醒。');
    }
    if (health.wantsSms && !health.smsPermission) {
      problems.add('提醒方式包含短信，但短信权限被拒绝了，'
          '所以只会弹通知、不会发短信。');
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('闹钟诊断日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // ---------- 健康状态（最该先看的）----------
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: problems.isEmpty
                        ? const Color(0xFFEAF7EE)
                        : const Color(0xFFFDECEA),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: problems.isEmpty
                            ? const Color(0xFFA5D6A7)
                            : const Color(0xFFF5A6A0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        problems.isEmpty ? '✔ 闹钟状态正常' : '⚠ 发现问题',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: problems.isEmpty
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFFB3261E),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '配置 ${health.configured} 条 · '
                        '系统里挂着 ${health.alive} 条 · '
                        '下一个闹钟 ${fmtTs(health.nextTrigger)} · '
                        '当前第 ${health.weekKnown ? health.week : "?"} 周',
                        style:
                            const TextStyle(fontSize: 12, height: 1.5),
                      ),
                      const SizedBox(height: 2),
                      // 原生侧实际存到的学期开始日：排查「界面设了但原生没收到」
                      Text(
                        '原生侧学期开始日：'
                        '${health.nativeTermStart.isEmpty ? "（空）" : health.nativeTermStart}',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF888888)),
                      ),
                      for (final String p in problems) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(p,
                            style: const TextStyle(
                                fontSize: 12, height: 1.6)),
                      ],
                      if (health.looksCleared) ...<Widget>[
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await context
                                .read<AppState>()
                                .regenerateCourseAlarms();
                            if (!mounted) return;
                            _toast(context, '已重新注册全部闹钟');
                          },
                          child: const Text('重新激活闹钟'),
                        ),
                      ],
                      // 一分钟测试闹钟：判断「系统到底会不会在到点叫醒应用」。
                      // 测试通知是立刻执行的，证明不了这件事。
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () async {
                          final int at = await AlarmScheduler
                              .scheduleTestAlarm(delaySeconds: 60);
                          if (!mounted) return;
                          if (at <= 0) {
                            _toast(context, '注册测试闹钟失败，请重试');
                            return;
                          }
                          final DateTime t =
                              DateTime.fromMillisecondsSinceEpoch(at);
                          _toast(
                              context,
                              '已排一条 ${t.hour.toString().padLeft(2, '0')}:'
                              '${t.minute.toString().padLeft(2, '0')} 的测试闹钟，'
                              '一分钟后再打开这里看日志：'
                              '出现「闹钟触发」= 系统投递正常，'
                              '什么都没有 = 系统在拦闹钟，要去放行电池优化。');
                        },
                        child: const Text('1 分钟后测试闹钟'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (lastFail != null) ...<Widget>[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDECEA),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF5A6A0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('⚠️ 最近一次短信没发出去：$lastFail',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFB3261E))),
                        const SizedBox(height: 6),
                        const Text(
                          '如果原因是「被系统拦截」，请按下面步骤放行：\n'
                          '1. 系统设置 → 应用与权限 → 权限管理\n'
                          '2. 找到「课表提醒」→ 短信\n'
                          '3. 打开「后台发送短信」\n'
                          '（vivo/iQOO 还可在 i管家 → 应用管理里允许后台运行）',
                          style: TextStyle(
                              fontSize: 12, height: 1.7),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                SelectableText(
                  '$shown\n\n'
                  '——————————————————\n'
                  '怎么看：\n'
                  '· 有「已注册闹钟」= 系统闹钟已设好\n'
                  '· 有「闹钟触发」= 系统按时唤醒了 App\n'
                  '· 「已调用系统短信接口」= 已请求系统发送\n'
                  '· 「短信已发出：成功交给运营商」= 真的发出去了\n'
                  '· 「❌ 短信发送失败」= 系统拒绝，看上面的放行步骤\n'
                  '· 「发送被跳过：号码是空」= 去设置页填接收号码\n'
                  '· 什么都没有 = 闹钟没注册上，回上一页点刷新图标重建',
                  style: const TextStyle(fontSize: 12.5, height: 1.6),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await AlarmScheduler.clearDiagnostics();
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) _toast(context, '日志已清空');
            },
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Text(text,
          style: const TextStyle(fontSize: 13, color: Color(0xFF888888))),
    );
  }
}

/// 供外部检查精确闹钟权限并给出提示
Future<String> checkExactAlarmPermission() async {
  final bool ok = await AlarmScheduler.canScheduleExactAlarms();
  return ok ? '已获得精确闹钟权限' : '未获得精确闹钟权限，提醒可能不准时';
}
