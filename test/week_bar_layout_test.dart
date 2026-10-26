// 周次栏布局回归测试
//
// 复现的真实问题：周次从第 9 周变成第 10 周只多了一个字符，
// 再加上「回到本周」按钮，整行宽度就超过屏幕 —— Row 溢出时不会换行，
// 而是把最右边的「下一周」箭头裁到屏幕外，看起来像按钮消失了。
//
// 这里**只测周次栏本身**（lib/widgets/week_bar.dart），不去 pump 整个课表页：
// 课表网格有自己的横向滚动区和固定宽度，塞进窄屏会先撑破网格，
// 干扰对周次栏的判断。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetable_app/widgets/week_bar.dart';

/// 把周次栏放进指定宽度里渲染
Future<void> pumpBar(
  WidgetTester tester, {
  required Size size,
  required int activeWeek,
  required int autoWeek,
  String termStart = '2026-08-31',
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            child: WeekBar(
              activeWeek: activeWeek,
              autoWeek: autoWeek,
              totalWeeks: 16,
              termStart: termStart,
              onPrev: () {},
              onNext: () {},
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('两位数周次 + 回到本周 不溢出（用户遇到的场景）',
      (WidgetTester tester) async {
    // 今天第 9 周，用户滑到第 10 周 → 显示「回到本周」
    await pumpBar(tester, size: const Size(320, 200), activeWeek: 10, autoWeek: 9);

    expect(tester.takeException(), isNull, reason: '周次栏不应该溢出');
    expect(find.byTooltip('上一周'), findsOneWidget);
    expect(find.byTooltip('下一周'), findsOneWidget);
    expect(find.text('回到本周'), findsOneWidget);

    // 光「存在」不够：被裁到屏幕外时 widget 依然存在但点不到。
    // 断言「下一周」箭头的右边界必须落在屏幕内。
    final Rect next = tester.getRect(find.byTooltip('下一周'));
    expect(next.right, lessThanOrEqualTo(320.0),
        reason: '「下一周」箭头被挤出屏幕右侧');
  });

  testWidgets('超窄屏（280）也不溢出', (WidgetTester tester) async {
    await pumpBar(tester, size: const Size(280, 200), activeWeek: 10, autoWeek: 9);
    expect(tester.takeException(), isNull,
        reason: '超窄屏下应该靠省略号收缩，而不是溢出');

    final Rect next = tester.getRect(find.byTooltip('下一周'));
    expect(next.right, lessThanOrEqualTo(280.0));
  });

  testWidgets('个位数周次（回归保护）', (WidgetTester tester) async {
    await pumpBar(tester, size: const Size(360, 200), activeWeek: 9, autoWeek: 9);
    expect(tester.takeException(), isNull);
    // 与当前周一致时不显示「回到本周」
    expect(find.text('回到本周'), findsNothing);
    expect(find.byTooltip('下一周'), findsOneWidget);
  });

  testWidgets('没有学期开始日时不显示日期区间，也不溢出',
      (WidgetTester tester) async {
    await pumpBar(
      tester,
      size: const Size(300, 200),
      activeWeek: 12,
      autoWeek: 16,
      termStart: '',
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('下一周'), findsOneWidget);
  });
}
