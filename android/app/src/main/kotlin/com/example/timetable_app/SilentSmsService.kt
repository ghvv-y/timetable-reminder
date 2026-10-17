package com.example.timetable_app

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * 静默服务（可选）。
 *
 * 本应用的核心发送逻辑在 SmsAlarmReceiver 中完成，不依赖本服务；
 * 保留它是为了后续需要「长时间保持发送通道」时扩展使用。
 *
 * 注意：本服务不创建通知渠道、不显示任何通知，保持完全静默。
 */
class SilentSmsService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf()
        return START_NOT_STICKY
    }
}
