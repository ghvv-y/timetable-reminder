// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 权限自检卡片：直接告诉用户当前每项权限是已授权还是被限制
//
// 放在设置页顶部，随时可以「重新检查」或「一键申请」。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/permissions.dart';

class PermissionCheckCard extends StatefulWidget {
  const PermissionCheckCard({super.key});

  @override
  State<PermissionCheckCard> createState() => _PermissionCheckCardState();
}

class _PermissionCheckCardState extends State<PermissionCheckCard> {
  bool _loading = true;
  List<PermissionCheckItem> _items = <PermissionCheckItem>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final AppState state = context.read<AppState>();
    final List<PermissionCheckItem> items = await state.permissionChecks();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final int problems =
        _items.where((PermissionCheckItem i) => !i.ok).length;

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text('权限自检',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (!_loading)
                  Text(
                    problems == 0 ? '全部就绪' : '$problems 项待处理',
                    style: TextStyle(
                      fontSize: 12,
                      color: problems == 0
                          ? const Color(0xFF3BA55D)
                          : const Color(0xFFD9534F),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: '重新检查',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else ...<Widget>[
              for (final PermissionCheckItem item in _items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        item.ok
                            ? Icons.check_circle_outline
                            : (item.known
                                ? Icons.error_outline
                                : Icons.help_outline),
                        size: 18,
                        color: item.ok
                            ? const Color(0xFF3BA55D)
                            : (item.known
                                ? const Color(0xFFD9534F)
                                : const Color(0xFFB0B0B0)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(item.name,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                            Text(item.detail,
                                style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.6,
                                    color: Color(0xFF666666))),
                            if (!item.ok && item.actionHint.isNotEmpty)
                              Text(item.actionHint,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF3A6BC8))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  FilledButton(
                    onPressed: () async {
                      final AppState state = context.read<AppState>();
                      final String summary =
                          await state.requestAllPermissions();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(summary),
                          duration: const Duration(seconds: 5),
                        ),
                      );
                      await _refresh();
                    },
                    child: const Text('一键申请'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () async {
                      final AppState state = context.read<AppState>();
                      final String? landed =
                          await state.openExactAlarmSettings();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(landed == null
                              ? '无法跳转，请手动到系统设置里开启'
                              : (landed == 'app_details'
                                  ? '该机型没有精确闹钟开关，已打开应用设置页'
                                  : '已打开设置页，请找到「闹钟和提醒」并允许')),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    },
                    child: const Text('精确闹钟设置'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
