// 用户输入校验：把「明显不合法但能存进去」的情况挡在保存之前
//
// 为什么单独抽出来：
//   这几条校验原来散在各个对话框里，有的写了、有的漏了（例如开始节次
//   有夹取、结束节次没有）。抽成纯函数之后既能统一复用，也能直接单测。

/// 结束节次不能小于开始节次。
///
/// 课表页按 `(end - start + 1) * 行高` 算课程块高度，
/// 区间倒置会算出负高度，直接导致布局异常。
int clampEndPeriod(int startPeriod, int endPeriod) =>
    endPeriod < startPeriod ? startPeriod : endPeriod;

/// 按星期的闹钟至少要选一天。
///
/// 不选任何星期时，原生侧算不出下一次触发时刻（返回 -1），
/// 闹钟看起来是「已启用」，但永远不会响 —— 用户会以为提醒坏了。
bool isValidAlarmWeekdays(String repeatType, List<int> weekdays) {
  if (repeatType != 'weekly') return true;
  return weekdays.isNotEmpty;
}

/// 作息时间必须「结束晚于开始」。
///
/// 倒置会让下课提醒早于上课提醒，课程时间展示也会错。
bool isValidPeriodRange(int startMinute, int endMinute) =>
    endMinute > startMinute;
