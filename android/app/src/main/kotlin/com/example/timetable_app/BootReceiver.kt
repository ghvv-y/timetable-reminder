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
