package com.example.timetable_app

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone

/**
 * 平台通道：
 *  - timetable_app/sms   发送短信（唯一动作，不产生任何本机通知）
 *  - timetable_app/alarm 注册 / 取消系统精确闹钟
 *  - timetable_app/file  打开系统文件选择器读取备份文件
 *
 * 到点后由 SmsAlarmReceiver 静默发送，不响铃、不震动、不弹通知。
 */
class MainActivity : FlutterActivity() {

    private val smsChannel = "timetable_app/sms"
    private val alarmChannel = "timetable_app/alarm"
    private val fileChannel = "timetable_app/file"
    private val screenChannel = "timetable_app/screen"
    private val imageChannel = "timetable_app/image"

    /** 文件选择请求码 */
    private val requestPickFile = 4711

    /** 截屏授权请求码 */
    private val requestScreenCapture = 4712

    private var pickFileResult: MethodChannel.Result? = null

    /** 截屏授权请求对应的 Dart 回调 */
    private var screenPermissionResult: MethodChannel.Result? = null

    /** 截屏功能使用的通道（服务截完图后回传结果用） */
    private var screenMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, smsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> {
                        val to = call.argument<String>("to") ?: ""
                        val message = call.argument<String>("message") ?: ""
                        val subId = call.argument<Int>("subscriptionId") ?: -1
                        result.success(sendSilently(to, message, subId))
                    }
                    "hasSmsPermission" -> result.success(hasSmsPermission())
                    "listSimCards" -> result.success(listSimCards())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, alarmChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
                    "exactAlarmStatus" -> result.success(exactAlarmStatus())
                    "requestExactAlarmPermission" -> result.success(openExactAlarmSettings())
                    "openAppSettings" -> result.success(openAppSettings())
                    "cancelAll" -> {
                        AlarmStore.cancelAll(this)
                        AlarmScheduler.cancelAll(this)
                        result.success(null)
                    }
                    "rescheduleAll" -> {
                        val array = call.argument<List<Map<String, Any?>>>("alarms")
                            ?: emptyList()
                        val to = call.argument<String>("to") ?: ""
                        val subId = call.argument<Int>("subscriptionId") ?: -1
                        val mode = call.argument<String>("mode")
                            ?: AlarmStore.MODE_BOTH
                        AlarmScheduler.rescheduleAll(this, array, to, subId, mode)
                        result.success(null)
                    }
                    // 闹钟诊断日志（没收到短信时用）
                    "readDiag" -> result.success(Diag.read(this))
                    "clearDiag" -> {
                        Diag.clear(this)
                        SmsFailure.clear(this)
                        result.success(null)
                    }
                    // 最近一次短信发送失败（界面醒目提示用）
                    "lastSmsFailure" -> {
                        val f = SmsFailure.last(this)
                        result.success(
                            if (f == null) null
                            else hashMapOf("msg" to f.first, "at" to f.second)
                        )
                    }
                    "clearSmsFailure" -> {
                        SmsFailure.clear(this)
                        result.success(null)
                    }
                    // 立即弹一条测试通知（验证提醒通道，不用等闹钟）
                    "testNotification" -> {
                        val text = call.argument<String>("text")
                            ?: "测试提醒：课表提醒已就绪"
                        ReminderNotifier.show(this, "test_notify", text)
                        result.success(true)
                    }
                    // 闹钟健康自检：配置了几条 / 系统里还真挂着几条
                    "alarmHealth" -> result.success(AlarmScheduler.alarmHealth(this))
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> pickTextFile(result)
                    else -> result.notImplemented()
                }
            }

        // 识别前的图像放大 / 增强（小字课表识别率提升用）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, imageChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val path = call.argument<String>("path") ?: ""
                        val scale = call.argument<Int>("scale") ?: 2
                        val enhance = call.argument<Boolean>("enhance") ?: true
                        if (path.isEmpty()) {
                            result.success(path)
                        } else {
                            result.success(
                                ImagePreprocess.prepare(this, path, scale, enhance)
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 悬浮球截屏：权限检查、启动 / 停止、截屏结果回传
        val screenChannelObj =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, screenChannel)
        screenMethodChannel = screenChannelObj
        ScreenCaptureService.captureChannel = screenChannelObj

        screenChannelObj.setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlay" -> result.success(
                    ScreenCaptureBridge.canDrawOverlay(this)
                )
                "isRunning" -> result.success(ScreenCaptureService.isRunning)
                "readDiagnostics" -> result.success(Diag.read(this))
                "clearDiagnostics" -> {
                    Diag.clear(this)
                    result.success(null)
                }
                "requestOverlayPermission" -> {
                    result.success(openOverlaySettings())
                }
                "start" -> requestScreenCapturePermission(result)
                "stop" -> {
                    ScreenCaptureBridge.stop(this)
                    result.success(null)
                }
                "getAutoReturn" -> result.success(ScreenOptions.autoReturn(this))
                "setAutoReturn" -> {
                    val v = call.argument<Boolean>("value") ?: true
                    ScreenOptions.setAutoReturn(this, v)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 打开「显示在其他应用上层」授权页 */
    private fun openOverlaySettings(): Boolean {
        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return startSafely(intent)
    }

    /**
     * 申请截屏授权。
     *
     * 先检查悬浮窗权限——没有的话先跳去授权，避免授权完截屏却没有悬浮球可用。
     */
    private fun requestScreenCapturePermission(result: MethodChannel.Result) {
        if (!ScreenCaptureBridge.canDrawOverlay(this)) {
            openOverlaySettings()
            result.error("need_overlay", "请先允许「显示在其他应用上层」", null)
            return
        }
        if (screenPermissionResult != null) {
            result.error("busy", "已有截屏授权请求在进行中", null)
            return
        }
        screenPermissionResult = result
        try {
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as android.media.projection.MediaProjectionManager
            @Suppress("DEPRECATION")
            startActivityForResult(mpm.createScreenCaptureIntent(), requestScreenCapture)
        } catch (e: Exception) {
            screenPermissionResult = null
            Log.w("TimetableApp", "申请截屏授权失败: ${e.message}")
            result.error("launch_failed", e.message, null)
        }
    }

    /** 打开系统文件选择器，读取所选文本文件内容 */
    private fun pickTextFile(result: MethodChannel.Result) {
        if (pickFileResult != null) {
            result.error("busy", "已有文件选择请求在进行中", null)
            return
        }
        pickFileResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("application/json", "text/plain")
                )
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, requestPickFile)
        } catch (e: Exception) {
            pickFileResult = null
            Log.w("TimetableApp", "打开文件选择器失败: ${e.message}")
            result.error("launch_failed", e.message, null)
        }
    }

    /** 文件选择 / 截屏授权的结果回调 */
    @Deprecated("FlutterActivity 基类未提供 registerForActivityResult，这里沿用经典回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestPickFile) {
            val pending = pickFileResult
            pickFileResult = null
            if (pending != null) {
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                pending.success(if (uri == null) null else readTextFromUri(uri))
            }
            return
        }

        if (requestCode == requestScreenCapture) {
            val pending = screenPermissionResult
            screenPermissionResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                ScreenCaptureBridge.start(this, resultCode, data, screenMethodChannel)
                pending?.success(true)
            } else {
                pending?.success(false)
            }
            return
        }

        super.onActivityResult(requestCode, resultCode, data)
    }

    /** 从 content:// 读取文本（显式 UTF-8，避免中文乱码） */
    private fun readTextFromUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { stream ->
                String(stream.readBytes(), Charsets.UTF_8)
            }
        } catch (e: Exception) {
            Log.w("TimetableApp", "读取文件失败: ${e.message}")
            null
        }
    }

    private fun hasSmsPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, android.Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED
    }

    /** 直接发送短信，不显示任何界面、不产生任何通知 */
    private fun sendSilently(to: String, message: String, subscriptionId: Int = -1): Boolean {
        if (to.isBlank() || message.isEmpty()) return false
        if (!hasSmsPermission()) return false
        return try {
            SilentSms.send(this, to, message, subscriptionId)
            true
        } catch (e: Exception) {
            Log.w("TimetableApp", "发送短信失败: ${e.message}")
            false
        }
    }

    /**
     * 列出手机上的 SIM 卡。
     *
     * 目的：双卡手机不指定卡时会弹「选择 SIM 卡」对话框，破坏静默发送。
     * 拿到各卡的 subscriptionId 后，用户可在设置页指定用哪张。
     */
    private fun listSimCards(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()

        // 【前置检查】没有 READ_PHONE_STATE 时，下面会返回空列表而不是报错，
        // 用户只会看到「读不到 SIM 卡」却不知道原因。这里明确记下来。
        val granted = ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            Diag.log(this, "读取 SIM 卡失败：没有 READ_PHONE_STATE 权限")
            Log.w("TimetableApp", "缺 READ_PHONE_STATE，无法列出 SIM 卡")
            return out
        }

        try {
            val sm = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                    as android.telephony.SubscriptionManager
            val list = sm.activeSubscriptionInfoList
            if (list == null) {
                Diag.log(this, "activeSubscriptionInfoList 返回 null")
                return out
            }
            for (info in list) {
                val number = try {
                    @Suppress("DEPRECATION")
                    info.number ?: ""
                } catch (_: Exception) {
                    ""
                }
                val carrier = try {
                    info.carrierName?.toString() ?: ""
                } catch (_: Exception) {
                    ""
                }
                val slot = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.simSlotIndex
                } else {
                    info.subscriptionId
                }
                val label = buildString {
                    append("卡").append(slot + 1)
                    if (carrier.isNotEmpty()) append(" · ").append(carrier)
                }
                out.add(
                    mapOf(
                        "subscriptionId" to info.subscriptionId,
                        "slotIndex" to slot,
                        "label" to label,
                        "number" to number
                    )
                )
            }
            Diag.log(this, "读到 ${out.size} 张 SIM 卡")
        } catch (e: Exception) {
            Diag.log(this, "读取 SIM 卡失败: ${e.javaClass.simpleName} / ${e.message}")
            Log.w("TimetableApp", "读取 SIM 卡失败: ${e.message}")
        }
        return out
    }

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    /**
     * 精确闹钟权限状态：
     *   granted 已授权
     *   denied  被限制（Android 12+ 未获得）
     *   na      系统版本低于 Android 12，安装即授权，无需处理
     */
    private fun exactAlarmStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "na"
        return if (canScheduleExactAlarms()) "granted" else "denied"
    }

    /**
     * 申请精确闹钟权限。
     *
     * 关键点：不同厂商（vivo / 小米 / 华为等）对 ACTION_REQUEST_SCHEDULE_EXACT_ALARM
     * 的处理差别很大，不少机型根本没有这个设置页。因此这里做「跳转失败自动回退」：
     * 跳不过去就打开本应用的系统设置页，而不是静默失败让用户以为点了没反应。
     *
     * 返回实际落到的页面标识：granted / exact_alarm / app_details，全部失败返回 null。
     */
    private fun openExactAlarmSettings(): String? {
        if (canScheduleExactAlarms()) return "granted"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (startSafely(intent)) return "exact_alarm"
        }

        // 回退：本应用的系统设置页
        if (openAppSettings() != null) return "app_details"

        return null
    }

    /** 打开本应用的系统设置页（应用详情） */
    private fun openAppSettings(): String? {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (startSafely(intent)) "app_details" else null
    }

    /** 安全启动页面：先检查可解析，避免 ActivityNotFoundException */
    private fun startSafely(intent: Intent): Boolean {
        return try {
            if (intent.resolveActivity(packageManager) == null) {
                Log.w("TimetableApp", "无可用页面: ${intent.action}")
                false
            } else {
                startActivity(intent)
                true
            }
        } catch (e: Exception) {
            Log.w("TimetableApp", "启动页面失败: ${intent.action} / ${e.message}")
            false
        }
    }
}

/** 闹钟配置存储（Dart 端每次变更后整体下发，这里全量覆盖） */
object AlarmStore {
    private const val PREF = "tt_alarms"
    private const val KEY_JSON = "alarms_json"
    private const val KEY_TO = "sms_to"
    private const val KEY_SUB_ID = "sms_sub_id"
    private const val KEY_MODE = "reminder_mode"
    private const val KEY_TERM_START = "term_start"
    private const val KEY_WEEK_OVERRIDE = "week_override"

    /** 提醒方式：both=通知+短信，notify=仅通知，sms=仅短信 */
    const val MODE_BOTH = "both"
    const val MODE_NOTIFY = "notify"
    const val MODE_SMS = "sms"

    fun save(
        context: Context,
        json: String,
        to: String,
        subscriptionId: Int = -1,
        mode: String = MODE_BOTH,
        termStart: String = "",
        weekOverride: Int = 0
    ) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_JSON, json)
            .putString(KEY_TO, to)
            .putInt(KEY_SUB_ID, subscriptionId)
            .putString(KEY_MODE, mode)
            .putString(KEY_TERM_START, termStart)
            .putInt(KEY_WEEK_OVERRIDE, weekOverride)
            .apply()
    }

    /** 学期开始日 yyyy-MM-dd，用于算「今天第几周」 */
    fun termStart(context: Context): String =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY_TERM_START, "") ?: ""

    /** 手动指定周次；0 表示按日期自动算 */
    fun weekOverride(context: Context): Int =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getInt(KEY_WEEK_OVERRIDE, 0)

    fun alarmsJson(context: Context): String =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY_JSON, "[]") ?: "[]"

    fun smsTo(context: Context): String =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY_TO, "") ?: ""

    /** 指定用哪张 SIM 卡发送（-1 表示未指定） */
    fun subscriptionId(context: Context): Int =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getInt(KEY_SUB_ID, -1)

    /** 提醒方式 */
    fun mode(context: Context): String =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY_MODE, MODE_BOTH) ?: MODE_BOTH

    /** 是否要弹通知 */
    fun wantNotify(context: Context): Boolean = mode(context) != MODE_SMS

    /** 是否要发短信 */
    fun wantSms(context: Context): Boolean = mode(context) != MODE_NOTIFY

    /** 取出全部闹钟配置（用于开机恢复与逐条调度） */
    fun all(context: Context): List<JSONObject> {
        val list = mutableListOf<JSONObject>()
        try {
            val arr = JSONArray(alarmsJson(context))
            for (i in 0 until arr.length()) {
                list.add(arr.getJSONObject(i))
            }
        } catch (e: Exception) {
            Log.w("TimetableApp", "闹钟数据解析失败: ${e.message}")
        }
        return list
    }

    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (alarm in all(context)) {
            val pi = AlarmScheduler.pendingIntent(context, alarm.optString("id"))
            am.cancel(pi)
            pi.cancel()
        }
    }
}

/** 精确闹钟注册 */
object AlarmScheduler {

    private const val ACTION_ALARM = "com.example.timetable_app.SEND_SMS_ALARM"

    /**
     * 构造某条闹钟的广播 Intent。
     *
     * 注册、取消、健康自检都必须用**完全一样**的 Intent，
     * 否则 PendingIntent 匹配不上（自检会全部显示"不在"）。
     */
    private fun baseIntent(context: Context, id: String): Intent =
        Intent(context, SmsAlarmReceiver::class.java).apply {
            action = ACTION_ALARM
            putExtra("alarmId", id)
            // 保证每条闹钟拿到不同的 PendingIntent
            data = Uri.parse("tt://alarm/$id")
        }

    fun pendingIntent(context: Context, id: String): PendingIntent {
        val intent = baseIntent(context, id)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getBroadcast(context, id.hashCode(), intent, flags)
    }

    /** 只查询「这条闹钟的 PendingIntent 还在不在」，不创建 */
    fun isAlive(context: Context, id: String): Boolean {
        val intent = baseIntent(context, id)
        return PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        ) != null
    }

    fun cancelAll(context: Context) {
        AlarmStore.cancelAll(context)
    }

    /**
     * 闹钟健康自检。
     *
     * 为什么需要：
     *   实测出现过「刚装好能响，过一两天就再也不响，日志里连触发记录都没有」。
     *   那是系统把闹钟清掉了（国产 ROM 冻结长期未使用的应用时会这样）。
     *   用户无从判断，只能凭感觉。
     *
     * 这里统计「配置里有几条」和「系统里真的还挂着几条」：
     *   两者差很多 = 闹钟已经被系统清掉，需要重新注册 + 放行后台权限。
     */
    fun alarmHealth(context: Context): Map<String, Any> {
        val configured = AlarmStore.all(context)
        var alive = 0
        for (a in configured) {
            val id = a.optString("id")
            if (id.isEmpty()) continue
            if (isAlive(context, id)) alive++
        }

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val next = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            am.nextAlarmClock?.triggerTime ?: -1L
        } else {
            -1L
        }

        // 通知权限：Android 13+ 没有 POST_NOTIFICATIONS 时，
        // NotificationManager.notify() 是**静默失败**（不抛异常）。
        // 也就是说提醒不会出现，而应用侧毫无感知 —— 必须显式检查。
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as android.app.NotificationManager
        val notifEnabled = nm.areNotificationsEnabled()

        return mapOf(
            "configured" to configured.size,
            "alive" to alive,
            "nextTrigger" to next,
            "week" to (currentWeekForFilter(context) ?: -1),
            "notifEnabled" to notifEnabled,
            "mode" to AlarmStore.mode(context)
        )
    }

    fun rescheduleAll(
        context: Context,
        alarms: List<Map<String, Any?>>,
        to: String,
        subscriptionId: Int = -1,
        mode: String = AlarmStore.MODE_BOTH,
        termStart: String = "",
        weekOverride: Int = 0
    ) {
        val arr = JSONArray()
        for (a in alarms) {
            arr.put(JSONObject(a))
        }
        AlarmStore.save(
            context, arr.toString(), to, subscriptionId, mode,
            termStart, weekOverride
        )
        AlarmStore.cancelAll(context)

        // 【重要】这里**必须把所有闹钟都注册上**，不能因为"本周没课"就跳过。
        // 否则第 9 周才开始的课，如果用户在开学那周装好后再没打开过 App，
        // 它就永远不会被注册、永远不会响。
        // 真正的过滤放在触发时做（见 SmsAlarmReceiver），那才是准确的。
        val week = currentWeekForFilter(context)
        var idle = 0
        for (a in AlarmStore.all(context)) {
            if (!isActiveThisWeek(a, week)) idle++
            scheduleOne(context, a)
        }
        Diag.log(
            context,
            "当前第 ${week ?: "?"} 周；其中 $idle 条本周没课（到点会自动跳过）"
        )
    }

    /**
     * 今天（或指定日期）是第几周。
     *
     * 与 Dart 端 time_utils.weekOfDate 保持一致的算法：
     *   周次 = (该日期所在周的周一 - 学期开始日所在周的周一) / 7 + 1
     * 返回 null 表示算不出来（没设学期开始日），此时不做周次过滤。
     */
    private fun weekOf(date: Calendar, termStart: String): Int? {
        if (termStart.isBlank()) return null
        return try {
            val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            fmt.isLenient = false
            val start = fmt.parse(termStart) ?: return null

            fun mondayOf(t: Long): Long {
                val c = Calendar.getInstance(TimeZone.getDefault())
                c.timeInMillis = t
                c.set(Calendar.HOUR_OF_DAY, 0)
                c.set(Calendar.MINUTE, 0)
                c.set(Calendar.SECOND, 0)
                c.set(Calendar.MILLISECOND, 0)
                // Calendar 里周日是第一天，换算成「周一为一周之首」
                val iso = c.get(Calendar.DAY_OF_WEEK)
                val back = if (iso == Calendar.SUNDAY) 6 else iso - Calendar.MONDAY
                c.add(Calendar.DAY_OF_YEAR, -back)
                return c.timeInMillis
            }

            val diff = mondayOf(date.timeInMillis) - mondayOf(start.time)
            val w = (diff / (7L * 24 * 60 * 60 * 1000)).toInt() + 1
            if (w < 1) 1 else w
        } catch (e: Exception) {
            null
        }
    }

    /** 当前周次；设置了手动周次时以手动值为准，0 表示自动 */
    private fun currentWeek(context: Context): Int? {
        val override = AlarmStore.weekOverride(context)
        if (override > 0) return override
        return weekOf(
            Calendar.getInstance(TimeZone.getDefault()),
            AlarmStore.termStart(context)
        )
    }

    /** 供接收器使用：当前是第几周（null = 算不出来，不做过滤） */
    fun currentWeekForFilter(context: Context): Int? = currentWeek(context)

    /**
     * 判断某个闹钟本周要不要响。
     *
     * 只有**课表闹钟**才按周次过滤。自定义闹钟是用户手动建的
     * （例如「每周三 14:00 提醒我交作业」），跟学期周次无关，任何时候都该响。
     *
     * 【踩过的坑】这里曾经靠「没有 startWeek 字段就用默认值 1、16」来判断，
     * 但 Dart 侧其实**总是会传**这两个字段（自定义闹钟传的是 1 和 16）。
     * 结果学期过到第 17 周以后，用户手动建的闹钟就全部静默失效了。
     * 现在改用显式的 isCourse 标记。
     */
    fun isActiveThisWeek(alarm: JSONObject, week: Int?): Boolean {
        // 自定义闹钟：不参与周次过滤
        if (!alarm.optBoolean("isCourse", false)) return true

        if (week == null) return true          // 算不出周次就不过滤
        val sw = alarm.optInt("startWeek", 1)
        val ew = alarm.optInt("endWeek", 16)
        val type = alarm.optString("weekType", "all")

        if (week < sw || week > ew) return false
        return when (type) {
            "odd" -> week % 2 == 1
            "even" -> week % 2 == 0
            else -> true
        }
    }

    fun scheduleOne(context: Context, alarm: JSONObject) {
        val id = alarm.optString("id")
        if (id.isEmpty()) return

        val runAt = nextTrigger(alarm)
        if (runAt <= 0L) {
            Diag.log(context, "闹钟 $id 算不出触发时间，未注册")
            return
        }
        scheduleAt(context, alarm, runAt)
    }

    /**
     * 把闹钟注册到系统的唯一入口。
     *
     * 为什么注册和「触发后的重排」必须走同一个函数：
     *   曾经 scheduleOne 用 setAlarmClock（闹钟时钟型，最抗冻结），
     *   而接收器重排时直接用了 setExactAndAllowWhileIdle。
     *   于是每周闹钟**第一次触发后就降级回普通型**，抗冻结能力全丢；
     *   更糟的是 Android 12+ 没有精确闹钟权限时，
     *   setExactAndAllowWhileIdle 抛 SecurityException 被 catch，
     *   重排彻底失败 —— 每周闹钟只响一次就永久停止。
     *   现在两处都走这里。
     *
     * 【优先用 setAlarmClock】这是系统里最强的一类闹钟：
     *   - 不受 Doze 限制
     *   - 优先级最高，系统会主动把应用拉起来
     *   - 对「应用冻结」的容忍度远高于普通闹钟
     *   - 不要求精确闹钟权限，不会抛 SecurityException
     * 代价：状态栏会出现一个闹钟小图标（系统对「下一个闹钟」的提示）。
     * 为了提醒能真的响，这个代价值得。
     */
    fun scheduleAt(context: Context, alarm: JSONObject, runAt: Long) {
        val id = alarm.optString("id")
        if (id.isEmpty() || runAt <= 0L) return

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context, id)
        val shown = java.text.SimpleDateFormat(
            "MM-dd HH:mm", java.util.Locale.US
        ).format(java.util.Date(runAt))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val showIntent = PendingIntent.getActivity(
                context,
                id.hashCode() + 3,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or
                        PendingIntent.FLAG_IMMUTABLE
            )
            try {
                am.setAlarmClock(
                    AlarmManager.AlarmClockInfo(runAt, showIntent), pi
                )
                Diag.log(context, "已注册闹钟 闹钟时钟型：$shown  $id")
                return
            } catch (e: Exception) {
                // 个别 ROM 可能拒绝 setAlarmClock，退回下面的精确/非精确路径
                Diag.log(context, "setAlarmClock 被拒（${e.message}），改用普通注册：$id")
            }
        }

        try {
            val mode = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                    if (am.canScheduleExactAlarms()) {
                        am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, runAt, pi)
                        "精确"
                    } else {
                        // 未获得精确闹钟权限时降级：仍会触发，但不保证分钟级准确
                        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, runAt, pi)
                        "非精确(缺精确闹钟权限)"
                    }
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, runAt, pi)
                    "精确"
                }
                else -> {
                    am.setExact(AlarmManager.RTC_WAKEUP, runAt, pi)
                    "精确"
                }
            }
            Diag.log(context, "已注册闹钟 $mode：$shown  $id")
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, runAt, pi)
            Diag.log(context, "精确闹钟被拒绝，降级为非精确：$id")
        }
    }

    /**
     * 计算下一次触发时刻：
     * - once：今天该时刻，若已过则顺延到明天
     * - daily：今天或明天
     * - weekly：weekdays 中最近的一天
     */
    fun nextTrigger(alarm: JSONObject): Long {
        val minute = alarm.optInt("timeMinute", -1)
        if (minute < 0 || minute >= 24 * 60) return -1L

        val repeatType = alarm.optString("repeatType", "once")

        val weekdays = mutableListOf<Int>()
        val ja = alarm.optJSONArray("weekdays")
        if (ja != null) {
            for (i in 0 until ja.length()) {
                weekdays.add(ja.optInt(i, 0))
            }
        }
        if (weekdays.isEmpty()) {
            val single = alarm.optInt("weekday", 0)
            if (single in 1..7) weekdays.add(single)
        }
        if (repeatType == "daily") {
            weekdays.clear()
            weekdays.addAll(1..7)
        }
        if (repeatType == "once" && weekdays.isEmpty()) {
            weekdays.add(0) // 0 表示不限定星期
        }

        for (offset in 0..7) {
            val cal = Calendar.getInstance(TimeZone.getDefault())
            cal.add(Calendar.DAY_OF_YEAR, offset)
            cal.set(Calendar.HOUR_OF_DAY, minute / 60)
            cal.set(Calendar.MINUTE, minute % 60)
            cal.set(Calendar.SECOND, 5)
            cal.set(Calendar.MILLISECOND, 0)
            if (cal.timeInMillis <= System.currentTimeMillis()) continue

            val isoDay = cal.get(Calendar.DAY_OF_WEEK) // 1=周日
            val mondayBased = if (isoDay == Calendar.SUNDAY) 7 else isoDay - 1

            if (weekdays.contains(mondayBased) || weekdays.contains(0)) {
                return cal.timeInMillis
            }
        }
        return -1L
    }
}
