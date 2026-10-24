// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app

import android.content.Context
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import java.lang.reflect.Method

/**
 * 静默短信发送：唯一的动作就是把备注原文发给指定号码。
 *
 * 注意：这里不做任何拼接、不添加签名、不修改标点，一个字都不改。
 *
 * 双卡适配：指定 subscriptionId 时直接走该卡，不会弹「选择 SIM 卡」对话框。
 * 这是「到点静默」的关键——弹框会让提醒变成需要人工操作的界面。
 */
object SilentSms {

    /** 单条短信上限（中文按 70 字计），超出则自动分条发送 */
    private const val MAX_LEN = 70

    fun send(
        context: Context,
        to: String,
        message: String,
        subscriptionId: Int = -1
    ) {
        val manager = obtainManager(context, subscriptionId)
        val tag = "发往$to"
        Diag.log(context, "调用短信接口：to=$to 正文长度=${message.length}")
        Log.i("TimetableApp", "发送短信 -> $to  subId=$subscriptionId")

        // 【必须传结果回调】否则发送失败时应用侧完全看不到，
        // 表现就是「日志说已调用接口、但对方始终没收到短信」。
        val sent = SmsStatusReceiver.sentIntent(context, tag)
        val delivered = SmsStatusReceiver.deliveredIntent(context, tag)

        if (message.length <= MAX_LEN) {
            manager.sendTextMessage(to, null, message, sent, delivered)
        } else {
            val parts: ArrayList<String> = manager.divideMessage(message)
            manager.sendMultipartTextMessage(to, null, parts, null, null)
            Diag.log(context, "正文超过 $MAX_LEN 字，已分成 ${parts.size} 条发送")
        }
        Log.i("TimetableApp", "已静默发送短信 -> $to")
    }

    /**
     * 取得可指定订阅的 SmsManager。
     *
     * 未指定卡时**主动查系统默认短信卡**，而不是直接用 SmsManager.getDefault()。
     * 原因：双卡手机上 getDefault 有时选不出卡，发送会静默失败
     * （实测出现「日志说已调用接口、用户没收到」的情况）。
     *
     * - Android 12+：公开 API createForSubscriptionId
     * - Android 5.1~11：反射调用隐藏方法，失败则退回默认卡
     */
    private fun obtainManager(context: Context, subscriptionId: Int): SmsManager {
        var subId = subscriptionId

        if (subId < 0) {
            try {
                val def = android.telephony.SubscriptionManager
                    .getDefaultSmsSubscriptionId()
                if (def >= 0) {
                    subId = def
                    Diag.log(context, "未指定卡，使用系统默认短信卡 subId=$def")
                } else {
                    // 只插了一张卡时直接用它
                    val sm = context.getSystemService(
                        Context.TELEPHONY_SUBSCRIPTION_SERVICE
                    ) as android.telephony.SubscriptionManager
                    val list = sm.activeSubscriptionInfoList
                    if (list != null && list.size == 1) {
                        subId = list[0].subscriptionId
                        Diag.log(context, "只检测到一张卡，使用 subId=$subId")
                    } else {
                        Diag.log(
                            context,
                            "没有默认短信卡（检测到 ${list?.size ?: 0} 张卡），" +
                                    "将由系统决定"
                        )
                    }
                }
            } catch (e: Exception) {
                Diag.log(context, "查询默认短信卡失败：${e.message}")
            }
        }

        val default: SmsManager = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

        if (subId < 0) return default

        // Android 12+ 公开 API
        if (Build.VERSION.SDK_INT >= 31) {
            return try {
                default.createForSubscriptionId(subId)
            } catch (e: Exception) {
                Log.w("TimetableApp", "createForSubscriptionId 失败，用默认卡: ${e.message}")
                default
            }
        }

        // 旧版本反射调用隐藏方法
        return try {
            val m: Method = SmsManager::class.java
                .getMethod("createForSubscriptionId", Int::class.javaPrimitiveType)
            (m.invoke(null, subId) as? SmsManager) ?: default
        } catch (e: Exception) {
            Log.w("TimetableApp", "反射取双卡 SmsManager 失败，用默认卡: ${e.message}")
            default
        }
    }
}
