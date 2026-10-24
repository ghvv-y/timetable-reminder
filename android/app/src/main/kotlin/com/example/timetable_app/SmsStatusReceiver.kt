// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager
import android.util.Log

/**
 * 短信发送结果接收器。
 *
 * 为什么需要它：
 *     `SmsManager.sendTextMessage` 是**异步**的 —— 调用不抛异常只代表
 *     「请求被接受了」，不代表短信真的发出去。之前没传结果回调，
 *     所以「到点了没收到短信」时完全查不出原因。
 *
 *     实测过一次：日志显示「已调用系统短信接口」但用户没收到短信，
 *     就是因为发送在系统层失败了，而应用侧看不到。
 *
 * 结果码含义（SmsManager.RESULT_ERROR_*）：
 *     NO_SERVICE          无信号 / 无服务
 *     RADIO_OFF           飞行模式或射频关闭
 *     NULL_PDU            格式错误
 *     GENERIC_FAILURE     其他失败（被系统拦截、SIM 异常等）
 *     RESULT_OK           已交给运营商
 */
class SmsStatusReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_SENT = "com.example.timetable_app.SMS_SENT"
        const val ACTION_DELIVERED = "com.example.timetable_app.SMS_DELIVERED"

        /** 建一个「短信已发出/已送达」的 PendingIntent */
        fun sentIntent(context: Context, tag: String): PendingIntent {
            val intent = Intent(context, SmsStatusReceiver::class.java).apply {
                action = ACTION_SENT
                putExtra("tag", tag)
            }
            return PendingIntent.getBroadcast(
                context,
                tag.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun deliveredIntent(context: Context, tag: String): PendingIntent {
            val intent = Intent(context, SmsStatusReceiver::class.java).apply {
                action = ACTION_DELIVERED
                putExtra("tag", tag)
            }
            return PendingIntent.getBroadcast(
                context,
                tag.hashCode() + 7,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        /** 把结果码翻译成人能看懂的话 */
        fun describe(code: Int): String = when (code) {
            Activity.RESULT_OK -> "成功交给运营商"
            SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "系统拒绝（可能被安全软件拦截）"
            SmsManager.RESULT_ERROR_NO_SERVICE -> "无信号/无服务"
            SmsManager.RESULT_ERROR_NULL_PDU -> "短信格式错误"
            SmsManager.RESULT_ERROR_RADIO_OFF -> "飞行模式或射频关闭"
            SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED -> "运营商不允许发送到该号码"
            SmsManager.RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED -> "运营商永久拒绝该号码"
            // 实测 vivo 在「后台发短信」被限制时返回 32，且几乎瞬间返回
            // （正常发送要几秒）。这类厂商码没有公开定义，只能靠特征判断。
            32 -> "被系统拦截：本应用在后台没有发短信权限（vivo/小米等机型的限制）"
            else -> "未知结果码 $code"
        }

        /**
         * 判断是不是「被系统立刻拒绝」。
         *
         * 实测特征：从调用到拿到结果只用了十几毫秒。
         * 真正的发送要走基站、通常需要数秒（成功案例实测 4 秒）。
         * 因此「毫秒级失败」基本可以确定是系统策略拦截，而不是网络问题，
         * 这种情况重试没有意义，要引导用户去系统设置里放行。
         */
        fun looksBlocked(elapsedMs: Long): Boolean = elapsedMs < 800
    }

    override fun onReceive(context: Context, intent: Intent) {
        val tag = intent.getStringExtra("tag") ?: ""
        if (intent.action == ACTION_SENT) {
            val code = resultCode
            if (code == Activity.RESULT_OK) {
                Diag.log(context, "短信已发出（$tag）：${describe(code)}")
                SmsFailure.clear(context)
            } else {
                // 这一行就是「为什么没收到短信」的答案
                val msg = describe(code)
                Diag.log(context, "❌ 短信发送失败（$tag）：$msg")
                Log.w("TimetableApp", "短信发送失败 code=$code tag=$tag")
                // 记下来，界面上要醒目地提示用户去放行
                SmsFailure.record(context, code, msg)
            }
        } else if (intent.action == ACTION_DELIVERED) {
            val code = resultCode
            if (code == Activity.RESULT_OK) {
                Diag.log(context, "短信已送达对方手机（$tag）")
                SmsFailure.clear(context)
            } else {
                Diag.log(context, "短信未送达（$tag）：结果码 $code")
            }
        }
    }
}

/**
 * 记录最近一次短信发送失败，供界面醒目提示。
 *
 * 为什么要单独存：失败原因如果只写在诊断日志里，用户不一定会去看。
 * 「闹钟到点没收到短信」是致命问题，必须在界面上直接告诉用户怎么解决。
 */
object SmsFailure {
    private const val PREF = "tt_sms_failure"
    private const val KEY_CODE = "code"
    private const val KEY_MSG = "msg"
    private const val KEY_AT = "at"

    fun record(context: Context, code: Int, msg: String) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
            .putInt(KEY_CODE, code)
            .putString(KEY_MSG, msg)
            .putLong(KEY_AT, System.currentTimeMillis())
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
            .clear().apply()
    }

    /** 返回 (失败说明, 发生时间戳)；没有失败时返回 null */
    fun last(context: Context): Pair<String, Long>? {
        val sp = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val msg = sp.getString(KEY_MSG, null) ?: return null
        return msg to sp.getLong(KEY_AT, 0L)
    }
}
