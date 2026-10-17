package com.example.timetable_app

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 轻量诊断日志。
 *
 * 目的：悬浮球、闹钟这类「配置了但看不到效果」的问题，光看代码猜不出来。
 * 这里把关键步骤写进应用私有文件，界面可以读出来显示，
 * 用户截个图就能定位，不需要连电脑抓 logcat。
 *
 * 记录内容：
 *   - 截屏服务启动/悬浮球添加/截屏结果
 *   - 闹钟注册（下次触发时间、是否精确）
 *   - 闹钟触发、短信发送结果（含「为什么没发」）
 */
object Diag {
    private const val FILE_NAME = "app_diag.log"
    private const val MAX_LINES = 200

    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Synchronized
    fun log(context: Context, message: String) {
        try {
            val f = File(context.cacheDir, FILE_NAME)
            val line = "${fmt.format(Date())}  $message\n"
            // 超过上限就截断，避免无限增长
            val existing = if (f.exists()) f.readLines() else emptyList()
            val kept = if (existing.size > MAX_LINES) {
                existing.subList(existing.size - MAX_LINES, existing.size)
            } else {
                existing
            }
            f.writeText(buildString {
                kept.forEach { append(it).append('\n') }
                append(line)
            })
        } catch (_: Exception) {
            // 诊断本身不能影响主流程
        }
    }

    @Synchronized
    fun read(context: Context): String {
        return try {
            val f = File(context.cacheDir, FILE_NAME)
            if (!f.exists()) "" else f.readText()
        } catch (_: Exception) {
            ""
        }
    }

    @Synchronized
    fun clear(context: Context) {
        try {
            File(context.cacheDir, FILE_NAME).delete()
        } catch (_: Exception) {
        }
    }
}
