package com.example.timetable_app

import android.content.Context

/**
 * 截屏功能的开关项。
 *
 * 单独放在一个 SharedPreferences 里，因为后台服务需要在没有 Flutter 引擎的情况下
 * 读取这些值（例如截屏完成后判断要不要把 App 拉回前台）。
 */
object ScreenOptions {

    private const val PREF = "tt_screen"
    private const val KEY_AUTO_RETURN = "auto_return"

    /** 截屏完成后是否自动返回课表界面 */
    fun autoReturn(context: Context): Boolean =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO_RETURN, true)

    fun setAutoReturn(context: Context, value: Boolean) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_AUTO_RETURN, value)
            .apply()
    }
}
