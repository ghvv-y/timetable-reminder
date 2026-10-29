// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 课程表页：周视图网格 + 今日提醒摘要
//
// 说明：课程格子里只显示「课程名 + 地点」，点一下可编辑或删除；
// 作息时间来自识别结果，用于计算每节课的上课与下课时刻。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/models.dart';
import '../widgets/week_bar.dart';
import '../model/period_time.dart';
import '../services/app_state.dart';
import '../services/file_gateway.dart';
import '../utils/time_utils.dart';
import '../utils/validators.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  /// 每节课的高度
  ///
  /// 演进过程：56 → 84 → 96。
  /// 56 时 2 节课只有 112px，「课程名 + 地点 + 时间」三行文字全被截断成
  /// 「校…」「楼4-…」。现在 96 让单节课也有足够高度放下课名和地点。
  static const double _rowHeight = 96;

  /// 星期表头高度
  static const double _headerHeight = 40;

  /// 左侧节次列宽度
  ///
  /// 用户课表的左列只放「节次号」，窄一点能给 7 个星期列留出更多空间。
  static const double _periodColumnWidth = 34;

  /// 每个星期列的最小宽度
  ///
  /// 手机屏幕 360dp 减去左边 34dp，7 列平摊每列只有 46dp——
  /// 4 个汉字的课名就被截断了。所以给一个最小宽度，装不下时整表左右滑动。
  static const double _dayColumnMinWidth = 62;

  /// 是否处于批量选择模式
  bool _selectMode = false;

  /// 已勾选的课程 id
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
        content: Text('将删除选中的 $count 门课程，以及它们对应的上下课提醒。\n'
            '此操作不可撤销。'),
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
    final int removed = await state.deleteCourses(_selected.toList());
    if (!mounted) return;
    _exitSelectMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $removed 门课程')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final int maxPeriod = _maxPeriod(state);
    final double gridHeight = maxPeriod * _rowHeight;

    // 每列至少有 _dayColumnMinWidth 宽；屏幕不够就整表左右滑动
    final double screenWidth = MediaQuery.of(context).size.width;
    final double available = screenWidth - _periodColumnWidth;
    final double dayWidth = (available / 7) < _dayColumnMinWidth
        ? _dayColumnMinWidth
        : available / 7;
    final double gridWidth = _periodColumnWidth + dayWidth * 7;
    final bool needHScroll = gridWidth > screenWidth + 1;

    // 表头与内容必须用同一套横向偏移，否则星期和格子会错位。
    // 纵向用 scrollview：行高调大后，小屏上一屏放不下所有节次。
    final Widget grid = SizedBox(
      width: gridWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _weekdayHeader(dayWidth),
          SizedBox(
            height: gridHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _periodColumn(state, maxPeriod),
                for (int d = 1; d <= 7; d++)
                  SizedBox(
                    width: dayWidth,
                    child: _dayColumn(state, d, maxPeriod),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      children: <Widget>[
        _weekBar(context, state),
        if (_selectMode) _selectBar(state),
        if (needHScroll)
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 2),
            child: Row(
              children: <Widget>[
                Icon(Icons.swipe, size: 13, color: Color(0xFFAAAAAA)),
                SizedBox(width: 4),
                Text('课表可以左右滑动看后面几天',
                    style: TextStyle(fontSize: 11, color: Color(0xFFAAAAAA))),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: needHScroll
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: grid,
                  )
                : grid,
          ),
        ),
        _todaySummary(state),
      ],
    );
  }

  /// 批量选择模式下显示的提示条
  Widget _selectBar(AppState state) {
    return Material(
      color: const Color(0xFFE8EFFF),
      child: InkWell(
        onTap: () {
          if (_selected.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('点一下课程格子即可勾选')),
            );
            return;
          }
          _deleteSelected(state);
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: <Widget>[
              const Icon(Icons.checklist, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _selected.isEmpty
                      ? '点课程格子勾选，可跨星期多选'
                      : '已选 ${_selected.length} 门',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _selected.length == state.courses.length
                    ? () => setState(() => _selected.clear())
                    : () => setState(() {
                          _selected
                            ..clear()
                            ..addAll(state.courses.map((Course c) => c.id));
                        }),
                child: Text(_selected.length == state.courses.length
                    ? '取消全选'
                    : '全选'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => _deleteSelected(state),
                child: Text('删除${_selected.isEmpty ? '' : '(${_selected.length})'}'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 需要画多少行节次
  ///
  /// 优先按识别到的作息表算，其次看课程跨到第几节。
  /// 都没有时给一个合理默认值——之前写死 12，用户课表只有 8 节，
  /// 底部会多出 4 行空白。
  int _maxPeriod(AppState state) {
    int max = 0;
    for (final PeriodTime p in state.periodTimes) {
      if (p.period > max) max = p.period;
    }
    for (final Course c in state.courses) {
      if (c.endPeriod > max) max = c.endPeriod;
    }
    if (max <= 0) return 10; // 还没有任何数据时的默认行数
    return max;
  }

  Widget _weekBar(BuildContext context, AppState state) {
    // 总周数以设置为准，没课程时也保持一致
    final int totalWeeks = state.settings.totalWeeks;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          WeekBar(
            activeWeek: state.activeWeek,
            autoWeek: state.autoWeek,
            totalWeeks: totalWeeks,
            termStart: state.settings.termStart,
            onPrev: state.activeWeek > 1
                ? () => state.setActiveWeek(state.activeWeek - 1)
                : null,
            onNext: state.activeWeek < totalWeeks
                ? () => state.setActiveWeek(state.activeWeek + 1)
                : null,
            onBackToCurrent: state.jumpToCurrentWeek,
          ),

          // ---- 第二行：操作按钮 ----
          //
          // 【踩过的坑】这些按钮曾经和周次信息挤在同一行 Row 里。
          // 手机屏幕窄时，最右边的「导入」和「清空」会被裁到屏幕外——
          // 看起来就像「导入按钮消失了」，其实还在，只是看不见也点不到。
          // 拆成独立一行后，任何宽度都放得下。
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (_selectMode)
                IconButton(
                  tooltip: '退出批量删除',
                  onPressed: _exitSelectMode,
                  icon: const Icon(Icons.close),
                )
              else ...<Widget>[
                TextButton.icon(
                  onPressed: () => _importSchedule(state),
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('导入课表'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                IconButton(
                  tooltip: '批量删除课程',
                  onPressed: () {
                    if (state.courses.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('还没有课程可删除')),
                      );
                    } else {
                      setState(() => _selectMode = true);
                    }
                  },
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
                IconButton(
                  tooltip: '清空全部课程',
                  onPressed: state.courses.isEmpty
                      ? null
                      : () => _clearAllCourses(state),
                  icon: const Icon(Icons.layers_clear_outlined),
                ),
              ],
            ],
          ),

          // 未设置学期开始日时给一条醒目提示，否则周次永远是第 1 周
          if (!state.weekIsConfigured)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => _quickSetTermStart(state),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF6E5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFFD591)),
                  ),
                  child: const Row(
                    children: <Widget>[
                      Icon(Icons.info_outline,
                          size: 15, color: Color(0xFFB8860B)),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '周次没设置，一直停在第 1 周 → 点这里把本周设为第 1 周',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8A6D3B)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 课表页快捷设置：把本周一设为学期第 1 周
  Future<void> _quickSetTermStart(AppState state) async {
    final DateTime mon = mondayOf(DateTime.now());
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('设置当前周次'),
        content: Text('把本周（${fmtDate(mon)} 那一周）设为学期的第 1 周吗？\n\n'
            '设置后，周次会按日期自动计算，以后不用再手动改。\n'
            '如果你现在其实不是第 1 周，请在设置页选择「选择日期」。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('设为第 1 周'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.setTermStart(fmtDate(mon));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已设为第 1 周（${fmtDate(mon)} 为周一）')),
    );
  }

  /// 从文件导入课表（电脑端识别工具生成的 课表导入.json）
  Future<void> _importSchedule(AppState state) async {
    final String? content = await FileGateway.pickTextFile();
    if (!mounted) return;
    if (content == null) {
      _snack('未选择文件，或当前平台不支持');
      return;
    }
    try {
      final int n = await state.importFromContent(content);
      if (!mounted) return;
      if (n == 0) {
        _snack('文件读取成功，但里面没有课程');
        return;
      }
      _snack('已导入 $n 门课。识别可能有个别错漏，'
          '点课程格子可以修改，长按可批量删除。');
    } catch (e) {
      if (!mounted) return;
      _snack('导入失败：文件格式不对');
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
      ));
  }

  /// 清空全部课程（识别导入效果不好时重来用）
  Future<void> _clearAllCourses(AppState state) async {
    final int count = state.courses.length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清空全部课程'),
        content: Text('将删除当前全部 $count 门课程，以及它们对应的上下课提醒。\n'
            '作息时间会保留。此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final int removed = await state.clearCourses();
    if (!mounted) return;
    _exitSelectMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清空 $removed 门课程')),
    );
  }

  Widget _weekdayHeader(double dayWidth) {
    return SizedBox(
      height: _headerHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: _periodColumnWidth),
          for (int d = 1; d <= 7; d++)
            SizedBox(
              width: dayWidth,
              child: Center(
                child: Text(
                  weekdayName(d).replaceFirst('周', ''),
                  style: const TextStyle(
                      fontSize: 13.5, color: Color(0xFF666666)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 左侧节次列
  ///
  /// 只显示节次号，**不再显示开始时间**：
  /// 之前给每个节次都画了开始时间，课程格子又画一次，同一行出现两个「08:00」，
  /// 看起来像重复了。开始时间统一由课程格子显示。
  Widget _periodColumn(AppState state, int maxPeriod) {
    return SizedBox(
      width: _periodColumnWidth,
      child: Column(
        children: <Widget>[
          for (int i = 1; i <= maxPeriod; i++)
            Container(
              height: _rowHeight,
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: 2),
              child: Text('$i',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF999999))),
            ),
        ],
      ),
    );
  }

  /// 某一天的课程列
  Widget _dayColumn(AppState state, int weekday, int maxPeriod) {
    final List<Course> dayCourses = state
        .coursesOfDay(weekday)
        .where((Course c) => c.occursInWeek(state.activeWeek))
        .toList();

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: Color(0xFFEDEFF3)),
        ),
      ),
      child: Stack(
        children: <Widget>[
          // 节次分隔线
          for (int i = 1; i <= maxPeriod; i++)
            Positioned(
              top: (i - 1) * _rowHeight,
              left: 0,
              right: 0,
              child: Container(height: 1, color: const Color(0xFFF2F4F8)),
            ),
          // 课程块
          // 边距收到 2px：列本身很窄，多留一点横向空间给课名
          for (final Course c in dayCourses)
            Positioned(
              top: (c.startPeriod - 1) * _rowHeight + 3,
              left: 2,
              right: 2,
              height: (c.endPeriod - c.startPeriod + 1) * _rowHeight - 7,
              child: _courseBlock(context, state, c),
            ),
        ],
      ),
    );
  }

  Widget _courseBlock(BuildContext context, AppState state, Course c) {
    // 参考用户课表的版式：格子里只显示**开始时间**（08:00 / 10:05）。
    // 完整区间太宽，在窄列里会换行成「08:00-」/「-08:45」，反而看不清。
    // 完整区间在点开课程详情里能看到。
    final PeriodTime? startPt = state.periodTime(c.startPeriod);
    final String timeText = startPt == null
        ? '第${c.startPeriod}节'
        : fmtMinute(startPt.startMinute);
    final bool selected = _selected.contains(c.id);

    return GestureDetector(
      onTap: () {
        // 批量选择模式下：点一下就是勾选 / 取消勾选
        if (_selectMode) {
          setState(() {
            if (selected) {
              _selected.remove(c.id);
            } else {
              _selected.add(c.id);
            }
          });
          return;
        }
        _showCourseSheet(context, state, c);
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(3, 3, 3, 3),
        decoration: BoxDecoration(
          color: _selectMode && selected
              ? const Color(0xFFD6E4FF)
              : const Color(0xFFE8EFFF),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _selectMode && selected
                ? const Color(0xFF2F6BFF)
                : const Color(0xFFC9D9FF),
            width: _selectMode && selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (_selectMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Icon(
                      selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 14,
                      color: const Color(0xFF2F6BFF),
                    ),
                  ),
                Expanded(
                  child: Text(
                    c.name,
                    // 列很窄，字号不能太大：12 号时 4 个汉字就超出宽度被截断。
                    // 11 号配合最多 3 行，能显示约 12 个汉字。
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B3A8B)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            if (c.room.isNotEmpty)
              Text(
                c.room,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10, height: 1.25, color: Color(0xFF5A6B95)),
              ),
            if (c.note.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.sticky_note_2_outlined,
                    size: 11, color: Color(0xFF8896B8)),
              ),
            const Spacer(),
            // 时间不换行：列宽很窄，一换行就变成「08:00-」/「-08:4」两行
            Text(
              timeText,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: const TextStyle(
                  fontSize: 9.5, height: 1.1, color: Color(0xFF8896B8)),
            ),
          ],
        ),
      ),
    );
  }

  /// 今日提醒摘要：让用户一眼看到今天会发出的短信时刻
  Widget _todaySummary(AppState state) {
    final int today = DateTime.now().weekday;
    final List<Alarm> list = state.alarmsOfDay(today)
        .where((Alarm a) => a.enabled)
        .toList()
      ..sort((Alarm a, Alarm b) => a.timeMinute.compareTo(b.timeMinute));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEDEFF3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '今天（${weekdayName(today)}）将发出 ${list.length} 条提醒短信',
            style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 22,
            child: list.isEmpty
                ? const Text('暂无提醒',
                    style: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (BuildContext context, int i) {
                      final Alarm a = list[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F4FA),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          '${fmtMinute(a.timeMinute)} ${a.label}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF44506B)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showCourseSheet(BuildContext context, AppState state, Course c) {
    final PeriodTime? startPt = state.periodTime(c.startPeriod);
    final PeriodTime? endPt = state.periodTime(c.endPeriod);
    final String timeRange = (startPt == null || endPt == null)
        ? '未识别到时间（请在识别页补充作息时间）'
        : '${fmtMinute(startPt.startMinute)} - ${fmtMinute(endPt.endMinute)}';

    final int preTime =
        startPt == null ? -1 : startPt.startMinute - state.settings.preClassMinutes;
    final int postTime =
        endPt == null ? -1 : endPt.endMinute - state.settings.postClassMinutes;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(c.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('${weekdayName(c.weekday)} 第${c.startPeriod}-${c.endPeriod}节',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),
              const SizedBox(height: 4),
              Text(timeRange,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),
              if (c.room.isNotEmpty)
                Text('地点：${c.room}',
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF666666))),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F7FB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  preTime < 0 || postTime < 0
                      ? '补齐作息时间后，才能计算提醒时刻'
                      : '上课提醒：${fmtMinute(preTime)}　下课提醒：${fmtMinute(postTime)}\n'
                          '短信正文（原样发送）：${c.name}'
                          '${c.room.isEmpty ? '' : ' ${c.room}'}'
                          '${c.note.isEmpty ? '' : ' ${c.note}'}',
                  style: const TextStyle(fontSize: 12, height: 1.7),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _editCourseDialog(context, state, c);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('编辑'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await state.deleteCourse(c.id);
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _editCourseDialog(BuildContext context, AppState state, Course c) {
    final TextEditingController nameCtl = TextEditingController(text: c.name);
    final TextEditingController roomCtl = TextEditingController(text: c.room);
    final TextEditingController noteCtl = TextEditingController(text: c.note);
    String weekType = c.weekType;
    int startPeriod = c.startPeriod;
    int endPeriod = c.endPeriod;

    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setLocal) {
            return AlertDialog(
              title: const Text('编辑课程'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameCtl,
                      decoration: const InputDecoration(labelText: '课程名'),
                    ),
                    TextField(
                      controller: roomCtl,
                      decoration: const InputDecoration(labelText: '地点'),
                    ),
                    TextField(
                      controller: noteCtl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: '备注（会写入提醒短信）',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        const Text('节次　'),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: startPeriod,
                            items: List<DropdownMenuItem<int>>.generate(
                              14,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text('第${i + 1}节'),
                              ),
                            ),
                            onChanged: (int? v) => setLocal(() {
                              startPeriod = v ?? startPeriod;
                              if (endPeriod < startPeriod) {
                                endPeriod = startPeriod;
                              }
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: endPeriod,
                            items: List<DropdownMenuItem<int>>.generate(
                              14,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text('到第${i + 1}节'),
                              ),
                            ),
                            onChanged: (int? v) => setLocal(() {
                              // 结束节次不能小于开始节次（否则课程块算出负高度）
                              endPeriod =
                                  clampEndPeriod(startPeriod, v ?? endPeriod);
                            }),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        const Text('周次　'),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: weekType,
                            items: const <DropdownMenuItem<String>>[
                              DropdownMenuItem<String>(
                                  value: 'all', child: Text('每周')),
                              DropdownMenuItem<String>(
                                  value: 'odd', child: Text('单周')),
                              DropdownMenuItem<String>(
                                  value: 'even', child: Text('双周')),
                            ],
                            onChanged: (String? v) =>
                                setLocal(() => weekType = v ?? weekType),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final Course updated = c.copyWith(
                      name: nameCtl.text.trim().isEmpty
                          ? c.name
                          : nameCtl.text.trim(),
                      room: roomCtl.text.trim(),
                      note: noteCtl.text.trim(),
                      startPeriod: startPeriod,
                      endPeriod: endPeriod,
                      weekType: weekType,
                    );
                    Navigator.pop(ctx);
                    await state.upsertCourse(updated);
                    await state.regenerateCourseAlarms();
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
