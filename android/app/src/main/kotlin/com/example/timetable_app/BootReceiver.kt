// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONObject

/**
 * 开机 / 重启后自动恢复全部闹钟。
 *
 * 系统闹钟在重启后会全部丢失，这里重新注册一遍，避免漏发提醒。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val appContext = context.applicationContext
        try {
            for (alarm: JSONObject in AlarmStore.all(appContext)) {
                AlarmScheduler.scheduleOne(appContext, alarm)
            }
        } catch (e: Exception) {
            Log.w("TimetableApp", "开机恢复闹钟失败: ${e.message}")
        }
    }
}
