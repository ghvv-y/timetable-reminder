package com.example.timetable_app.ocr

/**
 * 纯 Kotlin 图像工具：为「JVM 上可单测」而设计。
 *
 * 刻意不依赖 android.graphics.Bitmap —— 这样同一套代码能在：
 *   - 安卓上（从 Bitmap 转来）
 *   - 宿主 JVM 单元测试里（从 PNG 解出）
 * 完全一致地运行，识别管线可以在电脑上拿真实课表图片回归。
 *
 * 像素格式：packed RGB（0xRRGGBB），单通道用 IntArray 存 0..255 灰度。
 */
class OcrImage(
    val width: Int,
    val height: Int,
    /** packed RGB，行优先 */
    val pixels: IntArray
) {
    init {
        require(width > 0 && height > 0)
        require(pixels.size == width * height)
    }

    fun rgbAt(x: Int, y: Int): Int = pixels[y * width + x]

    fun red(v: Int): Int = (v shr 16) and 0xFF
    fun green(v: Int): Int = (v shr 8) and 0xFF
    fun blue(v: Int): Int = v and 0xFF

    /** 灰度图 0..255 */
    fun toGray(): IntArray {
        val out = IntArray(width * height)
        for (i in pixels.indices) {
            val v = pixels[i]
            // 与 PIL convert("L") 一致的经验系数
            out[i] = ((red(v) * 299 + green(v) * 587 + blue(v) * 114) / 1000)
        }
        return out
    }

    /** 裁剪（越界夹紧） */
    fun crop(x0: Int, y0: Int, x1: Int, y1: Int): OcrImage {
        val cx0 = x0.coerceIn(0, width)
        val cy0 = y0.coerceIn(0, height)
        val cx1 = x1.coerceIn(0, width)
        val cy1 = y1.coerceIn(0, height)
        val w = (cx1 - cx0).coerceAtLeast(0)
        val h = (cy1 - cy0).coerceAtLeast(0)
        if (w == 0 || h == 0) return OcrImage(1, 1, IntArray(1))
        val out = IntArray(w * h)
        for (y in 0 until h) {
            System.arraycopy(pixels, (cy0 + y) * width + cx0, out, y * w, w)
        }
        return OcrImage(w, h, out)
    }

    /**
     * 双线性缩放，映射约定与 cv2.resize INTER_LINEAR 一致：
     *   src = (dst + 0.5) * scale - 0.5
     * 半像素对齐看起来只差零点几像素，但对 OCR 是致命的 ——
     * 实测文字边缘像素会整批偏移，rec 模型直接读错或输出空白。
     */
    fun resize(newW: Int, newH: Int): OcrImage {
        if (newW == width && newH == height) return this
        val out = IntArray(newW * newH)
        val sx = width.toDouble() / newW
        val sy = height.toDouble() / newH

        for (y in 0 until newH) {
            val fy = (y + 0.5) * sy - 0.5
            val y0f = kotlin.math.floor(fy).toInt()
            val y0 = y0f.coerceIn(0, height - 1)
            val y1 = (y0f + 1).coerceAtMost(height - 1)
            val wy = (fy - y0f).toFloat().coerceIn(0f, 1f)
            for (x in 0 until newW) {
                val fx = (x + 0.5) * sx - 0.5
                val x0f = kotlin.math.floor(fx).toInt()
                val x0 = x0f.coerceIn(0, width - 1)
                val x1 = (x0f + 1).coerceAtMost(width - 1)
                val wx = (fx - x0f).toFloat().coerceIn(0f, 1f)

                val p00 = pixels[y0 * width + x0]
                val p01 = pixels[y0 * width + x1]
                val p10 = pixels[y1 * width + x0]
                val p11 = pixels[y1 * width + x1]

                val r = lerp4(p00 shr 16 and 0xFF, p01 shr 16 and 0xFF,
                    p10 shr 16 and 0xFF, p11 shr 16 and 0xFF, wx, wy)
                val g = lerp4(p00 shr 8 and 0xFF, p01 shr 8 and 0xFF,
                    p10 shr 8 and 0xFF, p11 shr 8 and 0xFF, wx, wy)
                val b = lerp4(p00 and 0xFF, p01 and 0xFF,
                    p10 and 0xFF, p11 and 0xFF, wx, wy)
                out[y * newW + x] = (r shl 16) or (g shl 8) or b
            }
        }
        return OcrImage(newW, newH, out)
    }

    private fun lerp4(a: Int, b: Int, c: Int, d: Int, wx: Float, wy: Float): Int {
        val top = a + (b - a) * wx
        val bot = c + (d - c) * wx
        return (top + (bot - top) * wy).toInt()
    }

    /** 灰度图缩放到 (newW,newH)（网格检测用，速度快于彩色） */
    fun resizeGray(newW: Int, newH: Int): IntArray {
        val gray = toGray()
        val out = IntArray(newW * newH)
        val sx = width.toDouble() / newW
        val sy = height.toDouble() / newH
        for (y in 0 until newH) {
            val fy = y * sy
            val y0 = fy.toInt().coerceIn(0, height - 1)
            val y1 = (y0 + 1).coerceAtMost(height - 1)
            val wy = (fy - y0).toFloat()
            for (x in 0 until newW) {
                val fx = x * sx
                val x0 = fx.toInt().coerceIn(0, width - 1)
                val x1 = (x0 + 1).coerceAtMost(width - 1)
                val wx = (fx - x0).toFloat()
                val a = gray[y0 * width + x0] + (gray[y0 * width + x1] - gray[y0 * width + x0]) * wx
                val b = gray[y1 * width + x0] + (gray[y1 * width + x1] - gray[y1 * width + x0]) * wx
                out[y * newW + x] = (a + (b - a) * wy).toInt()
            }
        }
        return out
    }

    companion object {
        /** 由灰度 IntArray 构造 OcrImage（单通道复制到 RGB） */
        fun fromGray(w: Int, h: Int, gray: IntArray): OcrImage {
            val px = IntArray(w * h)
            for (i in px.indices) {
                val g = gray[i]
                px[i] = (g shl 16) or (g shl 8) or g
            }
            return OcrImage(w, h, px)
        }
    }
}
