package com.example.timetable_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

/**
 * 悬浮球截屏服务。
 *
 * 用法：用户点「开启屏幕识别」→ 系统弹一次截屏授权 → 本服务启动并显示悬浮球。
 * 之后切到任意课表页面，点一下悬浮球，就把当前屏幕内容截下来存成图片，
 * 交给 Dart 侧做文字识别与导入。
 *
 * 关于通知：MediaProjection 规定必须以前台服务运行，系统会强制显示一个
 * 常驻通知与录制图标。这是系统行为，应用无法隐藏。
 * 因此本服务只在「屏幕识别开启期间」存在，关闭后立即停止，平时不打扰。
 */
class ScreenCaptureService : Service() {

    companion object {
        const val CHANNEL_ID = "screen_capture"
        const val NOTIFICATION_ID = 9001
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_FILE_PATH = "filePath"

        /** 悬浮球状态 */
        const val STATE_IDLE = 0
        const val STATE_CAPTURING = 1
        const val STATE_DONE = 2
        const val STATE_FAILED = 3

        /** 悬浮球点击时通知 Dart 侧有新截图 */
        var captureChannel: MethodChannel? = null

        /** 服务是否正在运行 */
        var isRunning: Boolean = false

        /**
         * 悬浮球外观的状态回调
         *
         * 由 showFloatingButton() 注册；截屏流程结束后调用它告诉用户「完成了」。
         */
        var captureStateListener: ((Int) -> Unit)? = null

        fun canDrawOverlay(context: Context): Boolean =
            Settings.canDrawOverlays(context)
    }

    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingCapture = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        Diag.log(this, "服务 onCreate")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Diag.log(this, "onStartCommand 进入")

        // 必须先在 5 秒内进入前台，否则系统会杀掉服务
        try {
            startForegroundCompat()
            Diag.log(this, "已进入前台（含 mediaProjection 类型）")
        } catch (e: Exception) {
            // Android 14+ 对前台服务类型校验很严，失败要明确报出来而不是静默消失
            Diag.log(this, "进入前台失败: ${e.javaClass.simpleName} / ${e.message}")
            Log.w("TimetableApp", "进入前台失败: ${e.message}")
            notifyError("foreground_failed: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
            ?: Activity.RESULT_CANCELED
        val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_RESULT_DATA)
        }

        Diag.log(this, "授权结果 resultCode=$resultCode data=${resultData != null}")

        if (resultCode == Activity.RESULT_OK && resultData != null) {
            // 顺序很关键：先让悬浮球出现，再建立投影。
            // 这样即使投影建立失败，用户至少能看到球、能重试，而不是「什么都没发生」。
            // 两步各自独立捕获异常，互不拖累。
            try {
                showFloatingButton()
            } catch (e: Throwable) {
                Diag.log(this, "添加悬浮球异常: ${e.javaClass.simpleName} / ${e.message}")
                notifyError("overlay_failed: ${e.message}")
            }

            try {
                startProjection(resultCode, resultData)
                Diag.log(this, "投影步骤完成")
            } catch (e: Throwable) {
                Diag.log(this, "建立投影异常: ${e.javaClass.simpleName} / ${e.message}")
                notifyError("projection_failed: ${e.message}")
            }
        } else {
            Diag.log(this, "未获得截屏授权，服务停止")
            Log.w("TimetableApp", "未获得截屏授权，服务停止")
            notifyError("no_permission")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /** 悬浮球：一个可拖动的小圆点，点一下截屏 */
    private fun showFloatingButton() {
        if (floatingView != null) return
        Diag.log(this, "进入 showFloatingButton")
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm
        Diag.log(this, "取到 WindowManager")

        val size = (56 * resources.displayMetrics.density).toInt()
        val container = FrameLayout(this)

        val label = TextView(this).apply {
            text = "扫"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 20f
            gravity = Gravity.CENTER
        }
        // 背景画不出来也不该阻止球出现——保底至少用一个带颜色的 TextView
        try {
            val circle = View(this).apply {
                background = ScreenCaptureBridge.circleBackground(this@ScreenCaptureService)
            }
            container.addView(circle, FrameLayout.LayoutParams(size, size))
            container.addView(label, FrameLayout.LayoutParams(size, size))
        } catch (e: Throwable) {
            Diag.log(this, "圆形背景创建失败，改用纯文本样式: ${e.message}")
            label.setBackgroundColor(0xFF2F6BFF.toInt())
            container.addView(label, FrameLayout.LayoutParams(size, size))
        }
        Diag.log(this, "悬浮球视图构建完成 size=$size")

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val metrics = resources.displayMetrics
        val params = WindowManager.LayoutParams(
            size, size, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = (metrics.widthPixels - size - 24).coerceAtLeast(0)
            y = (metrics.heightPixels / 2).coerceAtLeast(0)
        }
        Diag.log(
            this,
            "准备添加悬浮球 type=$type 屏幕=${metrics.widthPixels}x${metrics.heightPixels} " +
                    "位置=(${params.x},${params.y}) 尺寸=$size"
        )

        // 拖动 + 点击（移动距离很小才算点击）
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false

        // 点击 / 截屏状态反馈：靠边框颜色 + 文字告诉用户进展到哪一步
        //
        // 白色 = 待机，红色 = 正在截屏，绿色 = 截屏完成，橙色 = 截屏失败。
        // 之前只有「按下变红」，用户截完屏看不到任何结束标识。
        fun setState(state: Int) {
            val (stroke, label) = when (state) {
                STATE_CAPTURING -> 0xFFD9534F.toInt() to "…"
                STATE_DONE -> 0xFF3BA55D.toInt() to "✓"
                STATE_FAILED -> 0xFFE8A33D.toInt() to "!"
                else -> 0xFFFFFFFF.toInt() to "扫"
            }
            runCatching {
                (container.getChildAt(0) as? View)?.let { v ->
                    if (v.background is android.graphics.drawable.GradientDrawable) {
                        (v.background as android.graphics.drawable.GradientDrawable)
                            .setStroke((2 * resources.displayMetrics.density).toInt(), stroke)
                    }
                }
                (container.getChildAt(1) as? TextView)?.text = label
            }
        }
        captureStateListener = { state -> setState(state) }

        container.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    setState(STATE_CAPTURING)
                    Diag.log(this, "悬浮球按下")
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    // 判定阈值放宽到 24px，避免手指微抖被当成拖动
                    if (abs(dx) > 24 || abs(dy) > 24) {
                        if (!moved) setState(STATE_IDLE)   // 开始拖动就取消点击态
                        moved = true
                    }
                    params.x = startX + dx.toInt()
                    params.y = startY + dy.toInt()
                    runCatching { wm.updateViewLayout(container, params) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        Diag.log(this, "悬浮球点击 -> 开始截屏")
                        captureOnce()
                    } else {
                        setState(STATE_IDLE)
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    setState(STATE_IDLE)
                    true
                }
                else -> false
            }
        }

        val added = runCatching { wm.addView(container, params) }
        if (added.isSuccess) {
            Diag.log(this, "悬浮球添加成功")
        } else {
            val msg = added.exceptionOrNull()?.message ?: "未知错误"
            Diag.log(this, "悬浮球添加失败: $msg")
            Log.w("TimetableApp", "悬浮球添加失败: $msg")
            notifyError("overlay_failed: $msg")
        }
        floatingView = container
    }

    /** 把失败原因回传给 Dart 侧，便于界面给出明确提示而不是静默失败 */
    private fun notifyError(reason: String) {
        runCatching {
            val payload = HashMap<String, Any?>()
            payload["reason"] = reason
            captureChannel?.invokeMethod("onCaptureError", payload)
        }
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
        mediaProjection = mpm.getMediaProjection(resultCode, data)
        if (mediaProjection == null) {
            Diag.log(this, "getMediaProjection 返回 null")
            notifyError("projection_null")
            return
        }
        Diag.log(this, "拿到 MediaProjection 对象")

        // 【顺序至关重要】Android 14+ 强制要求：必须先注册回调，才能 createVirtualDisplay。
        // 否则抛 IllegalStateException:
        //   "Must register a callback before starting capture, to manage resources
        //    in response to MediaProjection states."
        // 之前把注册写在后面，导致投影建不起来、点悬浮球没反应。
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Diag.log(this@ScreenCaptureService, "系统停止了截屏")
                stopSelf()
            }
        }, mainHandler)
        Diag.log(this, "MediaProjection 回调已注册")

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.getRealMetrics(metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        Diag.log(this, "准备投影 ${width}x$height dpi=$density")

        try {
            imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            Diag.log(this, "ImageReader 创建成功")
        } catch (e: Throwable) {
            Diag.log(this, "ImageReader 创建失败: ${e.javaClass.simpleName} / ${e.message}")
            throw e
        }

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "timetable-capture",
            width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface, null, mainHandler
        )
        Diag.log(this, "VirtualDisplay=${virtualDisplay != null}，截屏就绪")
    }

    /** 截取当前屏幕，保存为 PNG，并通知 Dart 侧 */
    private fun captureOnce() {
        if (pendingCapture) {
            Diag.log(this, "上一次截屏还没完成，忽略本次点击")
            return
        }
        val reader = imageReader ?: run {
            // 投影没建起来时最常见的现象：球能点但没反应。
            // 只发错误、不再发一次「截屏失败」，否则界面会同时弹两条提示。
            Diag.log(this, "截屏失败：imageReader 为空（投影未建立）")
            notifyError("no_projection")
            // 这里也要复位，否则球会一直卡在「正在截屏」的红色
            setBallState(STATE_FAILED)
            mainHandler.postDelayed({ setBallState(STATE_IDLE) }, 1500)
            return
        }
        pendingCapture = true
        Diag.log(this, "开始截屏")
        setBallState(STATE_CAPTURING)

        // 给一帧的时间让画面刷新
        mainHandler.postDelayed({
            try {
                val image = reader.acquireLatestImage()
                if (image == null) {
                    Diag.log(this, "截屏失败：acquireLatestImage 返回 null")
                    notifyCapture(null)
                    setBallState(STATE_FAILED)
                    return@postDelayed
                }
                // 【关键】先把尺寸记下来。Image 一旦 close()，width/height 就不能再读，
                // 之前就是先 close 再用 image.width 导致
                // "IllegalStateException / Image is already closed"。
                val imgWidth = image.width
                val imgHeight = image.height

                val plane = image.planes[0]
                val buffer = plane.buffer
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                val rowPadding = rowStride - pixelStride * imgWidth

                val bitmap = Bitmap.createBitmap(
                    imgWidth + rowPadding / pixelStride,
                    imgHeight,
                    Bitmap.Config.ARGB_8888
                )
                bitmap.copyPixelsFromBuffer(buffer)
                image.close()   // 像素已经拷进 bitmap，这里可以安全关闭

                // 去掉右侧的填充像素
                val cropped = Bitmap.createBitmap(bitmap, 0, 0, imgWidth, imgHeight)
                val file = File(cacheDir, "screen_capture.png")
                FileOutputStream(file).use { out ->
                    cropped.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                bitmap.recycle()
                cropped.recycle()
                Diag.log(
                    this,
                    "截屏完成 ${imgWidth}x$imgHeight  ${file.length() / 1024} KB"
                )
                notifyCapture(file.absolutePath)

                // 结束时给一个明确标识：绿色 ✓
                setBallState(STATE_DONE)

                // 若开启了「截屏后自动返回」，把 App 拉回前台
                val autoReturn = ScreenOptions.autoReturn(this)
                Diag.log(this, "截屏完成，自动返回=$autoReturn")
                if (autoReturn) {
                    mainHandler.postDelayed({ bringAppToFront() }, 220)
                }
            } catch (e: Throwable) {
                Diag.log(this, "截屏异常: ${e.javaClass.simpleName} / ${e.message}")
                notifyCapture(null)
                setBallState(STATE_FAILED)
            } finally {
                pendingCapture = false
                // 过一会儿回到待机外观
                mainHandler.postDelayed({ setBallState(STATE_IDLE) }, 1500)
            }
        }, 180)
    }

    /** 更新悬浮球外观（由主线程执行） */
    private fun setBallState(state: Int) {
        mainHandler.post {
            runCatching { captureStateListener?.invoke(state) }
        }
    }

    /** 把 App 拉回前台（截屏完成后自动返回） */
    private fun bringAppToFront() {
        runCatching {
            @Suppress("DEPRECATION")
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent == null) {
                Diag.log(this, "自动返回失败：取不到启动 Intent")
                return@runCatching
            }
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT
            )
            startActivity(intent)
            Diag.log(this, "已自动返回课表界面")
        }.onFailure {
            Diag.log(this, "自动返回异常: ${it.message}")
        }
    }

    private fun notifyCapture(path: String?) {
        // 把结果回传给 Flutter（必须在主线程）
        val payload = HashMap<String, Any?>()
        payload["path"] = path
        runCatching {
            captureChannel?.invokeMethod("onScreenCaptured", payload)
        }.onFailure {
            Log.w("TimetableApp", "回传截图失败: ${it.message}")
        }
    }

    private fun startForegroundCompat() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "屏幕识别",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "开启屏幕识别时显示，关闭后自动消失"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("屏幕识别已开启")
            .setContentText("回到本应用可随时关闭；点悬浮球「扫」即可截取当前屏幕")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        isRunning = false
        Diag.log(this, "服务 onDestroy")
        runCatching {
            virtualDisplay?.release()
            imageReader?.close()
            mediaProjection?.stop()
        }
        floatingView?.let { v ->
            runCatching { windowManager?.removeView(v) }
        }
        floatingView = null
        virtualDisplay = null
        imageReader = null
        mediaProjection = null
        super.onDestroy()
    }
}

/** 悬浮球点击事件的备用入口（用于从通知栏等场景触发） */
class ScreenCaptureReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // 目前不需要处理外部广播，保留以便扩展
    }
}
