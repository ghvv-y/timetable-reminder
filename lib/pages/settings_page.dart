// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 设置页：短信接收号码、静默说明、作息时间编辑、导入导出
//
// 注意：静默开关由程序强制开启，界面上只做说明，不允许关闭。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/models.dart';
import '../model/period_time.dart';
import '../ocr/table_parser.dart';
import '../services/alarm_scheduler.dart';
import '../services/app_state.dart';
import '../services/file_gateway.dart';
import '../services/permissions.dart';
import '../services/sms_sender.dart';
import '../utils/time_utils.dart';
import 'build_stamp_card.dart';
import 'permission_check_card.dart';
import '../utils/validators.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 接收号码输入框
  ///
  /// 之前用的是 TextFormField + initialValue + onFieldSubmitted，
  /// 只有按键盘「完成」才保存——用户直接切走或按返回就丢了，表现为
  /// 「每次重开都要重新输号码」。现在改为即时保存。
  late final TextEditingController _smsToCtl;

  /// 防止程序回填文本时又触发一次保存，造成循环
  bool _syncing = false;

  /// 读到的 SIM 卡列表
  List<SimCard> _sims = <SimCard>[];
  bool _simsLoaded = false;

  @override
  void initState() {
    super.initState();
    final AppState state = context.read<AppState>();
    _smsToCtl = TextEditingController(text: state.settings.smsTo);
    _smsToCtl.addListener(_onSmsToChanged);
    // 进页面就读一次 SIM 卡
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSims());
  }

  @override
  void dispose() {
    _smsToCtl.removeListener(_onSmsToChanged);
    _smsToCtl.dispose();
    super.dispose();
  }

  /// 边输边存：输入即写入，不需要按任何按钮
  void _onSmsToChanged() {
    if (_syncing) return;
    final AppState state = context.read<AppState>();
    final String value = _smsToCtl.text.trim();
    if (value == state.settings.smsTo) return;
    state.updateSettings(state.settings.copyWith(smsTo: value));
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    // 若设置被别处修改（如导入备份），同步回输入框
    if (_smsToCtl.text.trim() != state.settings.smsTo) {
      _syncing = true;
      _smsToCtl.text = state.settings.smsTo;
      _syncing = false;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        const Text('设置',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),

        // 权限自检：直接告诉用户每项授权是被限制还是已授权
        const PermissionCheckCard(),

        // 后台存活：这是「过了两天就不提醒」的根本原因
        _backgroundSurvivalCard(state),

        // 学期与周次：设置一次学期开始日，之后周次自动跟随日期变化
        _termCard(state),

        // 提醒方式
        _card(
          title: '提醒方式',
          children: <Widget>[
            const Text(
              '手表不认「短信」，只认「通知」。而自己发给自己号码的短信，'
              '系统会当成你自己的对话，不打红点也不弹通知 —— 单卡手机就收不到提醒。\n'
              '改成本应用直接弹通知，可以绕开运营商和短信应用，最稳。',
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: Color(0xFF666666)),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: state.settings.reminderMode,
              onChanged: (String? v) {
                if (v == null) return;
                state.updateSettings(
                    state.settings.copyWith(reminderMode: v));
              },
              child: Column(
                children: <Widget>[
                  _modeTile(
                    value: 'notify',
                    title: '仅通知（推荐）',
                    subtitle: '手机不响不震动，通知栏出现提醒 → 手表同步震动',
                    selected: state.settings.reminderMode == 'notify',
                  ),
                  _modeTile(
                    value: 'both',
                    title: '通知 + 短信',
                    subtitle: '两种都发。双卡手机且两张卡号码不同时可用',
                    selected: state.settings.reminderMode == 'both',
                  ),
                  _modeTile(
                    value: 'sms',
                    title: '仅短信',
                    subtitle: '只在双卡手机上可靠（一张卡发给另一张卡的号码）',
                    selected: state.settings.reminderMode == 'sms',
                  ),
                ],
              ),
            ),
            // 短信总开关关闭时，选「通知+短信」「仅短信」都会被自动降级 ——
            // 必须说清楚，否则用户会以为选了短信却收不到。
            if (!state.settings.smsEnabled) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7E6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFE2A8)),
                ),
                child: const Text(
                  '「启用短信提醒」已关闭，所以无论这里选哪一项，'
                  '到点都只会弹通知、不会发短信。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            ],
          ],
        ),

        // 短信
        _card(
          title: '短信提醒',
          children: <Widget>[
            TextField(
              controller: _smsToCtl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: '短信接收号码',
                hintText: '填写你自己的手机号（短信会同步到手表）',
                border: const OutlineInputBorder(),
                helperText: state.settings.smsTo.isEmpty
                    ? '输入后自动保存，无需按任何按钮'
                    : '已保存：${state.settings.smsTo}',
                helperStyle: TextStyle(
                  color: state.settings.smsTo.isEmpty
                      ? const Color(0xFFD9534F)
                      : const Color(0xFF3BA55D),
                ),
              ),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
            ),
            const SizedBox(height: 12),
            // 双卡手机必须指定用哪张卡，否则每次发送都会弹「选择 SIM 卡」
            _simSelector(state),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用短信提醒'),
              subtitle: const Text('关闭后所有闹钟都不发送短信'),
              value: state.settings.smsEnabled,
              onChanged: (bool v) =>
                  state.updateSettings(state.settings.copyWith(smsEnabled: v)),
            ),
            const SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('静默模式（强制开启）'),
              subtitle: Text('到点不响铃、不震动、不弹通知，只发短信'),
              value: true,
              onChanged: null,
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await state.updateSettings(state.settings.copyWith(
                        smsTo: state.settings.smsTo,
                      ));
                      final bool ok = await state.requestSmsPermission();
                      if (context.mounted) {
                        _toast(context, ok ? '已获得发送短信权限' : '未获得发送短信权限');
                      }
                    },
                    child: const Text('申请短信权限'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      const Alarm probe = Alarm(
                        id: 'probe',
                        timeMinute: 0,
                        message: '测试短信：课表提醒已就绪',
                      );
                      final String r = await state.sendNow(probe);
                      if (context.mounted) {
                        _toast(context, r == 'success' ? '已发送' : '发送失败或平台不支持');
                      }
                    },
                    child: const Text('发送测试短信'),
                  ),
                ),
              ],
            ),
          ],
        ),

        // 提醒提前量
        _card(
          title: '提醒提前量',
          children: <Widget>[
            _minuteRow(
              label: '上课前',
              value: state.settings.preClassMinutes,
              onChanged: (int v) async {
                await state.updateSettings(
                    state.settings.copyWith(preClassMinutes: v));
                await state.regenerateCourseAlarms();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ScaffoldMessengerState messenger =
                          ScaffoldMessenger.of(context);
                      await AlarmScheduler.testNotification(
                          '测试提醒：实验课 9:00 上课 · A202');
                      if (!mounted) return;
                      messenger.showSnackBar(const SnackBar(
                          content: Text(
                              '通知已发出。看一下通知栏有没有出现，手表有没有同步')));
                    },
                    icon: const Icon(Icons.notifications_active_outlined,
                        size: 18),
                    label: const Text('测试通知'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final ScaffoldMessengerState messenger =
                          ScaffoldMessenger.of(context);
                      const Alarm probe = Alarm(
                        id: 'probe',
                        timeMinute: 0,
                        message: '测试短信：课表提醒已就绪',
                      );
                      final String r = await state.sendNow(probe);
                      if (!mounted) return;
                      messenger.showSnackBar(SnackBar(
                          content: Text(r == 'success'
                              ? '短信已交给系统发送'
                              : '短信发送失败，去闹钟页看诊断日志')));
                    },
                    icon: const Icon(Icons.sms_outlined, size: 18),
                    label: const Text('测试短信'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '「测试通知」最直观：点一下，通知栏出现提醒就说明通道正常。'
              '手表是否同步取决于华为运动健康里的通知权限。',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 8),
            _minuteRow(
              label: '下课前',
              value: state.settings.postClassMinutes,
              onChanged: (int v) async {
                await state.updateSettings(
                    state.settings.copyWith(postClassMinutes: v));
                await state.regenerateCourseAlarms();
              },
            ),
            const SizedBox(height: 6),
            const Text('修改后会自动按新提前量重新生成课表提醒时刻。',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
          ],
        ),

        // 作息时间
        _card(
          title: '作息时间（第几节 = 几点到几点）',
          children: <Widget>[
            if (state.periodTimes.isEmpty)
              const Text('暂无作息时间，请到「识别」页识别课表边侧的时间栏，或套用默认模板。',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF888888)))
            else
              for (final PeriodTime pt in state.periodTimes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('第${pt.period}节'),
                  subtitle: Text(
                      '${fmtMinute(pt.startMinute)} - ${fmtMinute(pt.endMinute)}'),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: () => _editPeriod(context, state, pt),
                ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: () async {
                    await state.setPeriodTimes(defaultPeriodTimes());
                    await state.regenerateCourseAlarms();
                    if (context.mounted) _toast(context, '已套用默认作息模板');
                  },
                  child: const Text('套用默认模板'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => _addPeriod(context, state),
                  child: const Text('新增节次'),
                ),
              ],
            ),
          ],
        ),

        // 数据
        _card(
          title: '数据与同步',
          children: <Widget>[
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出备份文件'),
              subtitle: const Text('手机与电脑之间可用它同步课表与闹钟'),
              onTap: () async {
                final String path = await state.exportToFile();
                if (context.mounted) _toast(context, '已导出：$path');
              },
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download_outlined),
              title: const Text('导入课表文件'),
              subtitle: const Text('选择电脑端识别生成的 课表导入.json'),
              onTap: () async {
                final ScaffoldMessengerState messenger =
                    ScaffoldMessenger.of(context);
                final String? content = await FileGateway.pickTextFile();
                if (!mounted) return;
                if (content == null) {
                  messenger.showSnackBar(
                      const SnackBar(content: Text('未选择文件或平台不支持')));
                  return;
                }
                try {
                  final int n = await state.importFromContent(content);
                  if (!mounted) return;
                  messenger.showSnackBar(SnackBar(
                      content: Text(n > 0
                          ? '已导入 $n 门课，共 ${state.periodTimes.length} 节作息时间'
                          : '文件已读取，但里面没有课程')));
                } catch (e) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                      const SnackBar(content: Text('导入失败：文件格式不对')));
                }
              },
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清空全部闹钟'),
              onTap: () async {
                await state.clearAlarms();
                if (context.mounted) _toast(context, '已清空');
              },
            ),
          ],
        ),

        // 发送日志
        _card(
          title: '短信发送记录（静默记录，不打扰）',
          children: <Widget>[
            if (state.logs.isEmpty)
              const Text('暂无记录',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF888888)))
            else
              for (final SmsLog log in state.logs.take(30))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    log.result == 'success'
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: log.result == 'success'
                        ? const Color(0xFF3BA55D)
                        : const Color(0xFFD9534F),
                  ),
                  title: Text(
                    '${log.sentAt.month}-${log.sentAt.day} '
                    '${fmtMinute(log.sentAt.hour * 60 + log.sentAt.minute)} → ${log.to}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(log.message,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
          ],
        ),

        const SizedBox(height: 8),
        const Text(
          '提醒链路：闹钟到点 → 静默发出短信 → 手机收到短信 → 华为运动健康同步到手表。\n'
          '请确保：已授予短信权限、系统短信通知未被关闭、手表与手机保持蓝牙连接、应用允许后台运行。',
          style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF888888)),
        ),
        const SizedBox(height: 12),
        const BuildStampCard(),
      ],
    );
  }

  /// 选卡控件（双卡手机用）
  ///
  /// 不指定卡时，Android 会弹出「选择 SIM 卡」对话框，破坏「到点静默」，
  /// 所以这里让用户一次选定，之后发送都直接走该卡。
  Widget _simSelector(AppState state) {
    if (!SmsSender.isSupported) {
      return const SizedBox.shrink();
    }

    final bool loaded = _simsLoaded;
    final List<SimCard> sims = _sims;
    final int selected = state.settings.smsSubscriptionId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text('发送用哪张卡',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadSims,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新读取'),
            ),
          ],
        ),
        if (!loaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('正在读取…',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF999999))),
          )
        else if (sims.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFD591)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '没读到 SIM 卡。这通常是因为系统没给「读取 SIM 卡」权限 —— '
                  '双卡手机缺它会导致发送时选不出卡，容易发不出短信。',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.6, color: Color(0xFF8A6D3B)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    FilledButton.tonal(
                      onPressed: _requestPhonePermission,
                      child: const Text('授予读取 SIM 卡权限'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _loadSims,
                      child: const Text('重新读取'),
                    ),
                  ],
                ),
              ],
            ),
          )
        else
          DropdownButtonFormField<int>(
            initialValue: sims.any((SimCard s) => s.subscriptionId == selected)
                ? selected
                : -1,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: <DropdownMenuItem<int>>[
              const DropdownMenuItem<int>(
                value: -1,
                child: Text('不指定（由系统决定，可能弹选卡框）'),
              ),
              for (final SimCard s in sims)
                DropdownMenuItem<int>(
                  value: s.subscriptionId,
                  child: Text(s.display),
                ),
            ],
            onChanged: (int? v) {
              state.updateSettings(
                  state.settings.copyWith(smsSubscriptionId: v ?? -1));
            },
          ),
        if (sims.length >= 2 && selected < 0)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('⚠️ 检测到多张卡且未指定，发送时可能弹出选卡框；建议在上面选一张',
                style: TextStyle(fontSize: 12, color: Color(0xFFD9534F))),
          ),

        // 【自己发给自己】的提醒
        //
        // 双卡手机建议「用卡1发、收到卡2」。原因：如果收信号码就是发送卡自己的
        // 号码，短信绕一圈回到同一台手机，系统会把它当成你自己的对话线程，
        // 很多机型（实测 vivo）不打红点、不弹通知，手表也就收不到。
        if (_isSelfSend(state, sims, selected))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF6E5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFD591)),
              ),
              child: const Text(
                '⚠️ 你现在是用「发送卡自己」发给「发送卡自己」的号码。\n'
                '这样短信回到同一台手机时，系统会当成你自己的对话，'
                '不打红点、也不弹通知，手表就收不到提醒。\n\n'
                '建议：接收号码填**另一张卡**的号码，发送用这张卡。'
                '这样短信就是一张卡发给另一张卡，通知和红点都正常。',
                style: TextStyle(
                    fontSize: 12, height: 1.6, color: Color(0xFF8A6D3B)),
              ),
            ),
          ),
      ],
    );
  }

  /// 判断是不是「自己发给自己」
  ///
  /// 只在能读到发送卡的号码时才判断得准；读不到就返回 false 不打扰。
  bool _isSelfSend(AppState state, List<SimCard> sims, int selected) {
    final String to = state.settings.smsTo.trim();
    if (to.isEmpty || selected < 0) return false;
    for (final SimCard s in sims) {
      if (s.subscriptionId != selected) continue;
      final String n = s.number.trim();
      if (n.isEmpty) return false;
      // 号码可能带 +86 前缀，只比后 11 位
      String tail(String v) {
        final String d = v.replaceAll(RegExp(r'\D'), '');
        return d.length > 11 ? d.substring(d.length - 11) : d;
      }

      return tail(n) == tail(to);
    }
    return false;
  }

  /// 「后台存活」引导卡片
  ///
  /// 为什么必须有这一张：
  ///   实测「刚装好能提醒，过一两天就再也不响，日志里连『闹钟触发』都没有」。
  ///   原因是国产系统（vivo 等）会把「长期没打开」的应用冻结，
  ///   冻结后系统闹钟不再投递，应用侧完全无能为力。
  ///
  ///   这不能只靠代码解决，必须让用户在系统里把本应用放行。
  ///   所以做成截图一样明确的步骤 + 一键跳到系统设置。
  Widget _backgroundSurvivalCard(AppState state) {
    return _card(
      title: '保证提醒一直有效（重要）',
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF6E5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFFD591)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '如果「刚装好能提醒，过一两天就不响了」，是系统把本应用冻结了。'
                '日志里会表现为完全没有「闹钟触发」记录。',
                style: TextStyle(
                    fontSize: 12.5, height: 1.6, color: Color(0xFF8A6D3B)),
              ),
              SizedBox(height: 8),
              Text(
                '请到系统设置里放行这三项：\n'
                '1. 自启动 —— 允许（否则重启后闹钟恢复不了）\n'
                '2. 后台运行 —— 允许（否则应用被冻结，闹钟不触发）\n'
                '3. 电池优化 —— 不限制（否则后台被限制）\n\n'
                'vivo/iQOO：i管家 → 应用管理 → 课表提醒 → 权限\n'
                '        设置 → 电池 → 后台耗电管理 → 允许后台高耗电\n'
                '小米/红米：设置 → 应用 → 课表提醒 → 省电策略 → 无限制',
                style: TextStyle(fontSize: 12, height: 1.75),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final String? landed =
                      await AlarmScheduler.openAppSettings();
                  if (!mounted) return;
                  _toast(context, landed == null
                      ? '没能打开设置页，请手动进系统设置'
                      : '已打开本应用的系统设置页');
                },
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('打开系统设置'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await state.regenerateCourseAlarms();
                  if (!mounted) return;
                  _toast(context, '已重新注册全部闹钟');
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新激活闹钟'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 提醒方式的一个选项
  Widget _modeTile({
    required String value,
    required String title,
    required String subtitle,
    required bool selected,
  }) {
    return RadioListTile<String>(
      value: value,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 11.5, height: 1.5)),
      selected: selected,
    );
  }

  /// 读一遍 SIM 卡
  Future<void> _loadSims() async {
    setState(() => _simsLoaded = false);
    final AppState state = context.read<AppState>();
    final List<SimCard> list = await state.loadSimCards();
    if (!mounted) return;
    setState(() {
      _sims = list;
      _simsLoaded = true;
    });
  }

  /// 申请「读取 SIM 卡」权限后重新读取
  ///
  /// 双卡手机没这个权限就读不到卡列表，发送时只能靠系统猜默认卡，
  /// 很容易出现「到点了但短信发不出去」。
  Future<void> _requestPhonePermission() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('请在弹窗里选择「允许」，允许后会自动重新读取 SIM 卡')));
    await performPermissionRequests(
      onSmsChanged: () async {},
    );
    if (!mounted) return;
    await _loadSims();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        content: Text(_sims.isEmpty
            ? '仍然没读到 SIM 卡，可到系统设置里手动允许「电话」权限'
            : '读到 ${_sims.length} 张卡，请在下面选定用哪张发送')));
  }

  /// 学期与周次卡片
  ///
  /// 只让用户设一次「学期第一周的周一」，之后周次由日期自动推算，
  /// 不需要每周手动改。也提供手动指定作为兜底。
  Widget _termCard(AppState state) {
    final AppSettings s = state.settings;
    final int? auto = weekOfDate(s.termStart);
    final bool configured = s.weekOverride > 0 || s.termStart.isNotEmpty;

    return _card(
      title: '学期与周次',
      children: <Widget>[
        // 当前生效的周次
        Row(
          children: <Widget>[
            const Text('当前是第',
                style: TextStyle(fontSize: 13.5, color: Color(0xFF666666))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('${state.activeWeek}',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2F6BFF))),
            ),
            Text('周 / 共 ${s.totalWeeks} 周',
                style:
                    const TextStyle(fontSize: 13.5, color: Color(0xFF666666))),
            const Spacer(),
            if (configured)
              Text(
                s.termStart.isEmpty
                    ? '手动指定'
                    : weekRangeText(s.termStart, state.activeWeek),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
              ),
          ],
        ),
        const SizedBox(height: 10),

        // 未配置时的醒目提示
        if (!configured)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFD591)),
            ),
            child: const Text(
              '还没设置学期开始日，周次一直停在第 1 周，课程可能会在没课的那几周误发提醒。\n'
              '请在上课第一周的周一打开本页，点下面的「设为第 1 周」即可。',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF8A6D3B)),
            ),
          ),
        const SizedBox(height: 10),

        // 学期开始日
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                s.termStart.isEmpty
                    ? '学期开始日：未设置'
                    : '学期开始日：${s.termStart}（第1周周一）',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            // 最省事的做法：今天就是第 1 周周一
            FilledButton.tonalIcon(
              onPressed: () async {
                final DateTime mon = mondayOf(DateTime.now());
                final ScaffoldMessengerState messenger =
                    ScaffoldMessenger.of(context);
                await state.setTermStart(fmtDate(mon));
                if (!mounted) return;
                messenger.showSnackBar(SnackBar(
                    content: Text('已设为第 1 周（${fmtDate(mon)} 为周一）')));
              },
              icon: const Icon(Icons.today, size: 18),
              label: const Text('设为第 1 周'),
            ),
            OutlinedButton.icon(
              onPressed: () => _pickTermStart(state),
              icon: const Icon(Icons.event, size: 18),
              label: const Text('选择日期'),
            ),
            if (s.weekOverride > 0)
              OutlinedButton.icon(
                onPressed: () async {
                  final ScaffoldMessengerState messenger =
                      ScaffoldMessenger.of(context);
                  await state.setWeekOverride(0);
                  if (!mounted) return;
                  messenger.showSnackBar(
                      const SnackBar(content: Text('已恢复自动周次')));
                },
                icon: const Icon(Icons.autorenew, size: 18),
                label: const Text('回到自动'),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // 总周数
        Row(
          children: <Widget>[
            const Text('一学期总周数', style: TextStyle(fontSize: 13)),
            const Spacer(),
            DropdownButton<int>(
              value: s.totalWeeks,
              underline: const SizedBox.shrink(),
              items: <DropdownMenuItem<int>>[
                for (final int n in <int>[14, 15, 16, 17, 18, 19, 20, 21, 22])
                  DropdownMenuItem<int>(value: n, child: Text('$n 周')),
              ],
              onChanged: (int? v) {
                if (v == null) return;
                state.updateSettings(s.copyWith(totalWeeks: v));
                state.refreshWeekIfNeeded(force: true);
              },
            ),
          ],
        ),

        const Divider(height: 22),

        // 手动指定周次（兜底）
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('手动指定周次'),
          subtitle: Text(s.weekOverride > 0
              ? '已固定为第 ${s.weekOverride} 周，不再随日期变化'
              : '一般不需要；只有学期开始日对不上时才用'),
          value: s.weekOverride > 0,
          onChanged: (bool on) async {
            await state.setWeekOverride(on ? state.activeWeek : 0);
          },
        ),
        if (s.weekOverride > 0) ...<Widget>[
          Row(
            children: <Widget>[
              IconButton(
                onPressed: s.weekOverride > 1
                    ? () => state.setWeekOverride(s.weekOverride - 1)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Expanded(
                child: Center(
                  child: Text('第 ${s.weekOverride} 周',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              IconButton(
                onPressed: s.weekOverride < s.totalWeeks
                    ? () => state.setWeekOverride(s.weekOverride + 1)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ],

        // 自动模式说明
        if (s.weekOverride == 0)
          Text(
            auto == null
                ? '设置学期开始日后，周次会自动按日期计算，不用手动改。'
                : '自动计算中：按学期开始日推算今天是第 $auto 周。'
                    '跨天后打开 App 会自动更新。',
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
      ],
    );
  }

  /// 选学期开始日（会归一到那一周的周一）
  Future<void> _pickTermStart(AppState state) async {
    final AppSettings s = state.settings;
    final DateTime now = DateTime.now();
    final DateTime firstDay = DateTime(now.year - 1, 1, 1);
    final DateTime lastDay = DateTime(now.year + 2, 12, 31);

    DateTime initial = now;
    final DateTime? saved = DateTime.tryParse(s.termStart);
    if (saved != null) initial = saved;

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDay,
      lastDate: lastDay,
      helpText: '选择学期第一周的任意一天',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;

    final DateTime mon = mondayOf(picked);
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await state.setTermStart(fmtDate(mon));
    if (!mounted) return;
    messenger.showSnackBar(
        SnackBar(content: Text('已设置：${fmtDate(mon)} 为第 1 周周一')));
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _minuteRow({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: <Widget>[
        Text(label, style: const TextStyle(fontSize: 13)),
        const Spacer(),
        DropdownButton<int>(
          value: value,
          items: const <DropdownMenuItem<int>>[
            DropdownMenuItem<int>(value: 0, child: Text('准点')),
            DropdownMenuItem<int>(value: 5, child: Text('提前 5 分钟')),
            DropdownMenuItem<int>(value: 10, child: Text('提前 10 分钟')),
            DropdownMenuItem<int>(value: 15, child: Text('提前 15 分钟')),
            DropdownMenuItem<int>(value: 20, child: Text('提前 20 分钟')),
          ],
          onChanged: (int? v) => onChanged(v ?? value),
        ),
      ],
    );
  }

  void _editPeriod(BuildContext context, AppState state, PeriodTime pt) async {
    final TimeOfDay? s = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: pt.startMinute ~/ 60, minute: pt.startMinute % 60),
    );
    if (s == null || !context.mounted) return;
    final TimeOfDay? e = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: pt.endMinute ~/ 60, minute: pt.endMinute % 60),
    );
    if (e == null || !context.mounted) return;

    final int startMinute = s.hour * 60 + s.minute;
    final int endMinute = e.hour * 60 + e.minute;
    // 作息必须「结束晚于开始」，否则下课提醒会早于上课提醒
    if (!isValidPeriodRange(startMinute, endMinute)) {
      _toast(context, '结束时间必须晚于开始时间，已取消本次修改');
      return;
    }

    final List<PeriodTime> list = state.periodTimes
        .map((PeriodTime p) => p.period == pt.period
            ? PeriodTime(
                period: pt.period,
                startMinute: startMinute,
                endMinute: endMinute,
              )
            : p)
        .toList();
    await state.setPeriodTimes(list);
    await state.regenerateCourseAlarms();
  }

  void _addPeriod(BuildContext context, AppState state) async {
    int next = 1;
    for (final PeriodTime p in state.periodTimes) {
      if (p.period >= next) next = p.period + 1;
    }
    final List<PeriodTime> list = <PeriodTime>[...state.periodTimes];
    list.add(PeriodTime(
        period: next, startMinute: 8 * 60, endMinute: 8 * 60 + 45));
    await state.setPeriodTimes(list);
    // 新增节次后必须重建提醒：之前因「查不到该节次作息」而没生成闹钟的课程，
    // 现在能生成了。只 setPeriodTimes 的话它们仍然没有提醒。
    await state.regenerateCourseAlarms();
  }

  static void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }
}
