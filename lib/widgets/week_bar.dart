// 课表页顶部的「周次栏」
//
// 为什么单独抽成组件：
//   这一行曾经是「固定宽度文字 + Spacer + 按钮」的 Row，周次从第 9 周
//   变成第 10 周只多一个字符，再加上「回到本周」按钮，整行就超出屏幕。
//   Row 溢出时**不会换行**，而是把最右边的「下一周」箭头裁到屏幕外 ——
//   看起来就像按钮消失了（用户实际遇到的就是这个）。
//
//   抽出来之后可以单独做布局测试（见 test/week_bar_layout_test.dart），
//   不用把整页（含可横向滚动的课表网格）一起塞进测试窗口。
//
// 布局原则：
//   左侧信息区放进 Expanded，日期区间再套 Flexible + 省略号；
//   右侧的「回到本周」和两个箭头是固定元素，任何宽度下都必须可见可点。

import 'package:flutter/material.dart';

import '../utils/time_utils.dart';

class WeekBar extends StatelessWidget {
  /// 当前查看的周次
  final int activeWeek;

  /// 按学期开始日算出来的真实周次（null = 算不出来）
  final int? autoWeek;

  /// 一学期总周数
  final int totalWeeks;

  /// 学期开始日（yyyy-MM-dd），为空时不显示日期区间
  final String termStart;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onBackToCurrent;

  const WeekBar({
    super.key,
    required this.activeWeek,
    required this.autoWeek,
    required this.totalWeeks,
    required this.termStart,
    this.onPrev,
    this.onNext,
    this.onBackToCurrent,
  });

  /// 是否显示了「回到本周」（看了别的周才有意义）
  bool get showsBackToCurrent => activeWeek != (autoWeek ?? activeWeek);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              const Text('第',
                  style: TextStyle(fontSize: 14, color: Color(0xFF666666))),
              const SizedBox(width: 6),
              Text('$activeWeek',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              // 周数本身也允许收缩：极窄屏上先压这里，不挤箭头
              Flexible(
                child: Text('周 / 共 $totalWeeks 周',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF666666))),
              ),
              // 日期区间信息价值最低，空间不够时优先省略
              if (termStart.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    weekRangeText(termStart, activeWeek),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF999999)),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (showsBackToCurrent)
          TextButton(
            onPressed: onBackToCurrent,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('回到本周', style: TextStyle(fontSize: 12)),
          ),
        IconButton(
          tooltip: '上一周',
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: '下一周',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
