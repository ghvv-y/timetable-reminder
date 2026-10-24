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
 * 闹钟到点时的接收器：静默发送短信。
 *
 * 严格静默：不响铃、不震动、不发通知，也不启动任何界面。
 * 发送完成后如果是重复闹钟，会自动安排下一次触发。
 */
class SmsAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val alarmId = intent.getStringExtra("alarmId") ?: run {
            Diag.log(context, "闹钟触发但没带 alarmId，忽略")
            return
        }
        val appContext = context.applicationContext
        Diag.log(appContext, "闹钟触发：$alarmId")

        // 后台线程完成发送，避免阻塞主线程
        val pending = goAsync()
        Thread {
            try {
                val alarm = AlarmStore.all(appContext)
                    .firstOrNull { it.optString("id") == alarmId }
                if (alarm == null) {
                    Diag.log(appContext, "闹钟已不在配置里（可能被删除）：$alarmId")
                    Log.w("TimetableApp", "闹钟不存在: $alarmId")
                    return@Thread
                }

                val to = AlarmStore.smsTo(appContext)
                val subId = AlarmStore.subscriptionId(appContext)
                val message = alarm.optString("message")

                // ---------- 0. 周次过滤（本周没课就别吵）----------
                //
                // 为什么放在触发时而不是注册时：
                //   闹钟是按「每周几」循环的，但课表有起止周和单双周。
                //   只在注册时过滤的话，第 9 周才开始的课会因为注册那天
                //   「本周没课」而永远不注册。所以全部注册、到点再判断。
                val week = AlarmScheduler.currentWeekForFilter(appContext)
                if (!AlarmScheduler.isActiveThisWeek(alarm, week)) {
                    Diag.log(
                        appContext,
                        "本周（第 $week 周）没有这门课，已跳过：$message"
                    )
                    // 跳过也要安排下一次，否则这个闹钟就永远停了
                    rescheduleNext(appContext, alarm, alarmId)
                    return@Thread
                }

                Diag.log(
                    appContext,
                    "准备提醒（第 $week 周）-> 方式=${AlarmStore.mode(appContext)} " +
                            "号码='$to' 正文=$message"
                )

                // ---------- 1. 弹通知（主要提醒方式）----------
                //
                // 手表不认「短信」，只认「通知」。而自己发给自己的短信，
                // 系统短信应用会当成自己的对话，不打红点也不弹通知 ——
                // 单卡手机就彻底收不到提醒。所以这里由本应用直接发一条
                // 静默通知，绕开运营商、短信应用和厂商的后台发短信限制。
                if (AlarmStore.wantNotify(appContext) && message.isNotEmpty()) {
                    ReminderNotifier.show(appContext, alarmId, message)
                }

                // ---------- 2. 发短信（可选）----------
                if (AlarmStore.wantSms(appContext)) {
                    if (to.isBlank()) {
                        Diag.log(
                            appContext,
                            "短信被跳过：接收号码是空的（去设置页填写；" +
                                    "只想要通知可把提醒方式设为「仅通知」）"
                        )
                    } else if (message.isEmpty()) {
                        Diag.log(appContext, "短信被跳过：闹钟正文是空的")
                    } else {
                        try {
                            // 带上指定的卡号：双卡手机不加这个会弹「选择 SIM 卡」
                            SilentSms.send(appContext, to, message, subId)
                            Diag.log(appContext, "已调用系统短信接口：$to")
                        } catch (e: Exception) {
                            Diag.log(
                                appContext,
                                "发送失败：${e.javaClass.simpleName} / ${e.message}"
                            )
                            Log.w("TimetableApp", "静默发送失败: ${e.message}")
                        }
                    }
                } else {
                    Diag.log(appContext, "提醒方式不含短信，跳过发送")
                }

                // 重复闹钟：安排下一次
                rescheduleNext(appContext, alarm, alarmId)
            } finally {
                pending.finish()
            }
        }.start()
    }

    /** 重复闹钟：安排下一次触发；「仅一次」的则从配置里移除 */
    private fun rescheduleNext(
        appContext: Context,
        alarm: JSONObject,
        alarmId: String
    ) {
        val repeatType = alarm.optString("repeatType", "once")
        if (repeatType == "once") {
            // 仅一次：触发后移除该条，避免重复触发
            Diag.log(appContext, "仅一次的闹钟，已从配置移除")
            removeAlarm(appContext, alarmId)
            return
        }

        val next = AlarmScheduler.nextTrigger(alarm)
        if (next <= 0L) {
            Diag.log(appContext, "重复闹钟算不出下一次触发时间")
            return
        }

        // 重排必须走和初始注册相同的入口（闹钟时钟型 + 降级链）。
        //
        // 【踩过的坑】这里曾经直接用 setExactAndAllowWhileIdle：
        //   1. 每周闹钟第一次触发后就从「闹钟时钟型」降级回普通型，
        //      防冻结能力全丢；
        //   2. Android 12+ 没精确闹钟权限时它会抛 SecurityException，
        //      重排失败 —— 每周闹钟只响一次就永久停止。
        AlarmScheduler.scheduleAt(appContext, alarm, next)
    }

    /**
     * 「仅一次」的闹钟触发后，把它从配置里移除。
     *
     * 【踩过的坑】这里曾经只传了前 4 个参数：
     *     AlarmStore.save(context, arr, smsTo, subId)
     * 而 save 后来加上了 mode / termStart / weekOverride 三个参数（有默认值），
     * 于是每次一次性闹钟触发后：
     *     提醒方式  「仅通知」  ->  变回「通知+短信」
     *     学期开始日  已设置    ->  被清空
     *     手动周次    已设置    ->  被清零
     * 也就是用户设置被悄悄重置。
     * 教训：加参数时用了默认值，老调用点会静默丢掉新字段。
     * 现在把当前值原样带回去。
     */
    private fun removeAlarm(context: Context, alarmId: String) {
        val rest = AlarmStore.all(context).filter { it.optString("id") != alarmId }
        val arr = org.json.JSONArray()
        for (item in rest) {
            arr.put(item)
        }
        AlarmStore.save(
            context,
            arr.toString(),
            AlarmStore.smsTo(context),
            AlarmStore.subscriptionId(context),
            AlarmStore.mode(context),
            AlarmStore.termStart(context),
            AlarmStore.weekOverride(context)
        )

        // 同时把这条闹钟的 PendingIntent 取消掉。
        // 不取消的话它会一直留在系统里，健康自检会把它算成"还挂着"，
        // 让用户误以为闹钟没问题。
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE)
                    as android.app.AlarmManager
            am.cancel(AlarmScheduler.pendingIntent(context, alarmId))
        } catch (e: Exception) {
            Log.w("TimetableApp", "取消 PendingIntent 失败: ${e.message}")
        }
    }
}
