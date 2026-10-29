// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 到点提醒通知。
 *
 * 为什么需要它（而不是只发短信）：
 *     手表不认「短信」，只认「通知」。短信之所以能提醒，是因为它触发了
 *     短信应用去弹通知。而「自己发给自己」的短信，系统短信应用会当成
 *     自己的对话线程，不打红点也不弹通知 —— 单卡手机就彻底收不到提醒了。
 *
 *     这里让本应用**直接发通知**，绕开运营商、绕开短信应用、绕开厂商的
 *     「后台发短信」限制，一步到位。
 *
 * 静默保证：
 *     通知渠道不设铃声、不设震动、不做横幅弹窗（importance = DEFAULT 而非 HIGH），
 *     所以手机自己不响、不震、不弹窗；但通知会出现在通知栏，
 *     手表同步后就能把人叫醒 —— 这正是提醒的入口。
 */
object ReminderNotifier {

    /**
     * 通知渠道 id。
     *
     * 【为什么带 _v2】Android 规定**渠道建好之后重要性不能由应用改高**
     * （只能由用户在系统设置里改）。老版本用 IMPORTANCE_DEFAULT 建的
     * `class_reminder` 已经存在了，改动量级对它无效 ——
     * 必须换新 id 才能让新等级生效。旧渠道会在 ensureChannel 里删掉。
     */
    const val CHANNEL_ID = "class_reminder_v2"

    /** 旧渠道（低等级），建好就删，避免设置页里出现两个同名渠道 */
    private const val OLD_CHANNEL_ID = "class_reminder"

    /** 通知 id 的基数，避免和截屏服务的通知撞号 */
    private const val ID_BASE = 20000

    /**
     * 建立通知渠道（可重复调用）。
     *
     * 关键设置：
     *   - importance = HIGH：这是**手表能收到**的关键。
     *     华为运动健康（以及多数手表伴侣 App）会把低等级/静默通知过滤掉，
     *     低等级渠道在手机上也可能被折叠，手表端就更容易丢。
     *     注意：HIGH 只是「优先级高」，本渠道 setSound(null)+enableVibration(false)，
     *     所以手机依然不响不震、也不会横幅弹窗。
     *   - setSound(null)：不出声
     *   - enableVibration(false)：不震动
     */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager

        val channel = NotificationChannel(
            CHANNEL_ID,
            "上课提醒",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "课表提醒：到点静默提示，供手表同步"
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)

        // 旧的低等级渠道不再使用，删掉以免用户在两处开关之间困惑
        try {
            if (manager.getNotificationChannel(OLD_CHANNEL_ID) != null) {
                manager.deleteNotificationChannel(OLD_CHANNEL_ID)
            }
        } catch (_: Throwable) {
        }
    }

    /** 当前渠道的重要性等级；-1 表示系统低于 Android 8（无渠道概念） */
    fun channelImportance(context: Context): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return -1
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
        val ch = manager.getNotificationChannel(CHANNEL_ID) ?: return -1
        return ch.importance
    }

    /** 渠道是否被用户/系统关掉了（importance == NONE） */
    fun channelBlocked(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return channelImportance(context) == NotificationManager.IMPORTANCE_NONE
    }

    /**
     * 弹一条提醒通知。
     *
     * @param text 提醒正文（就是备注原文，不做任何改写）
     */
    fun show(context: Context, alarmId: String, text: String) {
        try {
            ensureChannel(context)

            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager

            // 点通知回到应用
            val open = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            }
            val pi = PendingIntent.getActivity(
                context,
                alarmId.hashCode(),
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle("课表提醒")
                .setContentText(text)
                // 长文本展开后完整显示（短信有 70 字限制，通知没有）
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                // HIGH 提升「被手表伴侣 App 转发」的概率；
                // 渠道里已关掉声音和震动，所以手机仍然安静
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                // 锁屏也显示完整内容，手表拿到的正文才不会被遮挡
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setSound(null)
                .setVibrate(null)
                .setDefaults(0)
                .build()

            manager.notify(ID_BASE + (alarmId.hashCode() and 0xffff), n)
            Diag.log(context, "已弹出提醒通知：$text")
            Log.i("TimetableApp", "已弹出提醒通知: $text")
        } catch (e: Throwable) {
            // 通知失败不能影响短信发送
            Diag.log(context, "弹通知失败：${e.javaClass.simpleName} / ${e.message}")
            Log.w("TimetableApp", "弹通知失败: ${e.message}")
        }
    }
}
