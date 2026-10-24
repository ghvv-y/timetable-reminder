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
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * 识别前的图像预处理。
 *
 * 为什么需要：
 * 课表截图里每个课程格只有 ~80 像素宽，格子里的课程名、教师、周次等
 * 小字实际高度可能只有 8~10 像素。ML Kit 对这么小的中文字符基本认不出来，
 * 表现为「只认出个别字」「整行漏掉」。
 *
 * 做法：先放大（默认 2 倍，双线性插值），可选提高对比度，
 * 再交给识别引擎。放大后的字达到可识别尺寸，识别率明显提升。
 * 这是纯本地图像处理，不联网、不加依赖。
 */
object ImagePreprocess {

    /** 单边最大像素数，避免超大图导致内存溢出 */
    private const val MAX_SIDE = 6000

    /**
     * 生成适合识别的图片，返回新文件路径；失败时返回原路径。
     *
     * @param scale 放大倍数（1 = 只做对比度增强，不放大）
     * @param enhance 是否提高对比度（对彩色底纹的小字有帮助）
     */
    fun prepare(
        context: Context,
        inputPath: String,
        scale: Int = 2,
        enhance: Boolean = true
    ): String {
        return try {
            val src = BitmapFactory.decodeFile(inputPath)
            if (src == null) {
                Log.w("TimetableApp", "预处理失败：无法解码 $inputPath")
                return inputPath
            }

            // 先算实际能用的放大倍数，避免超过内存上限
            var s = if (scale < 1) 1 else scale
            while (s > 1 &&
                (src.width * s > MAX_SIDE || src.height * s > MAX_SIDE)
            ) {
                s--
            }

            val outW = src.width * s
            val outH = src.height * s

            val dst = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(dst)
            val paint = Paint().apply {
                isFilterBitmap = true      // 双线性插值，边缘更平滑，利于识别
                isAntiAlias = true
            }
            if (enhance) {
                // 提高对比度与亮度：彩色底纹上的深色小字对比度往往不足
                val cm = ColorMatrix()
                val contrast = 1.6f
                val translate = (-0.5f * contrast + 0.5f) * 255f + 12f
                cm.set(
                    floatArrayOf(
                        contrast, 0f, 0f, 0f, translate,
                        0f, contrast, 0f, 0f, translate,
                        0f, 0f, contrast, 0f, translate,
                        0f, 0f, 0f, 1f, 0f
                    )
                )
                paint.colorFilter = ColorMatrixColorFilter(cm)
            }
            canvas.drawBitmap(src, null,
                android.graphics.Rect(0, 0, outW, outH), paint)

            val file = File(context.cacheDir, "ocr_prepared.png")
            FileOutputStream(file).use { out ->
                dst.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            src.recycle()
            dst.recycle()

            Diag.log(
                context,
                "识别前处理：${src.width}x${src.height} → ${outW}x$outH " +
                        "(放大 ${s} 倍, 增强=$enhance, ${file.length() / 1024} KB)"
            )
            file.absolutePath
        } catch (e: Throwable) {
            Log.w("TimetableApp", "预处理异常: ${e.message}")
            inputPath   // 出问题就用原图，绝不阻断识别流程
        }
    }
}
