package com.example.timetable_app

import android.content.Context
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView

/**
 * 屏幕截取（悬浮球）的桥接逻辑：权限检查、启动 / 停止服务。
 *
 * 说明：本功能与「闹钟到点绝对静默」互不干扰——
 * 只有在用户主动开启屏幕识别时，才会申请悬浮窗与前台服务权限，
 * 关闭后服务立即停止、通知立即消失。
 */
object ScreenCaptureBridge {

    private const val TAG = "TimetableApp"

    /** 是否已授予「显示在其他应用上层」权限 */
    fun canDrawOverlay(context: Context): Boolean =
        Settings.canDrawOverlays(context)

    /**
     * 启动悬浮球截屏。
     *
     * 需要先把 MediaProjection 的授权结果传进服务，所以流程是：
     *   1. Dart 请求 -> MainActivity 弹出系统截屏授权
     *   2. 用户允许 -> 带着 resultCode / resultData 启动 ScreenCaptureService
     */
    fun start(
        context: Context,
        resultCode: Int,
        resultData: Intent,
        captureChannel: io.flutter.plugin.common.MethodChannel?
    ) {
        ScreenCaptureService.captureChannel = captureChannel
        val intent = Intent(context, ScreenCaptureService::class.java).apply {
            putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, resultData)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Log.i(TAG, "屏幕截取服务已启动")
        } catch (e: Exception) {
            Log.w(TAG, "启动屏幕截取服务失败: ${e.message}")
        }
    }

    /** 停止悬浮球截屏，通知与录制图标随之消失 */
    fun stop(context: Context) {
        try {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "停止屏幕截取服务失败: ${e.message}")
        }
    }

    /** 悬浮球视图背景（圆形） */
    fun circleBackground(context: Context): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0xFF2F6BFF.toInt())
            val stroke = (2 * context.resources.displayMetrics.density).toInt()
            setStroke(stroke, 0xFFFFFFFF.toInt())
        }
}
