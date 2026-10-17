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

    const val CHANNEL_ID = "class_reminder"

    /** 通知 id 的基数，避免和截屏服务的通知撞号 */
    private const val ID_BASE = 20000

    /**
     * 建立通知渠道（只需一次，重复调用无副作用）。
     *
     * 关键设置：
     *   - importance = DEFAULT：会出现在通知栏（这是手表能同步的前提）
     *   - setSound(null)：不出声
     *   - enableVibration(false)：不震动
     *   - 没有设置高优先级，所以不会横幅弹窗
     */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "上课提醒",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "课表提醒：到点静默提示，供手表同步"
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
        }
        manager.createNotificationChannel(channel)
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
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
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
