package com.example.timetable_app.ocr

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer

/**
 * PP-OCR v3 识别引擎（纯 Kotlin，可在安卓与宿主 JVM 上运行）。
 *
 * 算法参数与桌面端 RapidOCR 逐项对齐（读自其源码）：
 *   det：最小边缩放到 736（取整到 32 的倍数），
 *        ImageNet 归一化 (0.485/0.456/0.406, 0.229/0.224/0.225, 1/255)，
 *        输出 sigmoid 概率图，阈值 0.3。
 *   rec：高 48、宽上限 320，/255 → -0.5 → /0.5，CTC 贪心解码，
 *        字符表取自 rec 模型元数据（见 loadCharTable 的说明）。
 */
class OcrEngine(
    detModelPath: String,
    recModelPath: String
) : AutoCloseable {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val detSession: OrtSession =
        env.createSession(detModelPath, OrtSession.SessionOptions())
    private val recSession: OrtSession =
        env.createSession(recModelPath, OrtSession.SessionOptions())

    /**
     * 字符表：[0]=blank, [1]=stray quote, [2..]=字符, [末尾]=' '（与 RapidOCR 完全一致）。
     * 字典嵌在 rec 模型的元数据里，直接读会话元数据，不需要单独文件。
     */
    private val charTable: Array<String> =
        loadCharTable(recSession.metadata.customMetadata["character"] ?: "")

    /** det 概率图（模型分辨率下，值 0..1），scale 为 原图/模型图 比例 */
    data class DetResult(val width: Int, val height: Int, val prob: FloatArray, val scale: Double)

    /**
     * 运行 det，返回概率图。
     * 输入：整格图像。输出：模型分辨率下的概率图（原始尺寸 = 模型尺寸 / scale）。
     */
    fun runDet(image: OcrImage): DetResult {
        // ---- 预处理：最小边 736，取整到 32 的倍数 ----
        val (resized, ratio) = detResize(image)

        val input = FloatArray(3 * resized.width * resized.height)
        val ch = resized.width * resized.height
        val pixels = resized.pixels
        for (i in pixels.indices) {
            val v = pixels[i]
            val r = (v shr 16 and 0xFF) / 255f
            val g = (v shr 8 and 0xFF) / 255f
            val b = (v and 0xFF) / 255f
            input[i] = (r - 0.485f) / 0.229f
            input[ch + i] = (g - 0.456f) / 0.224f
            input[2 * ch + i] = (b - 0.406f) / 0.225f
        }

        val tensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(input),
            longArrayOf(1L, 3L, resized.height.toLong(), resized.width.toLong())
        )
        tensor.use {
            val result = detSession.run(mapOf("x" to it)).get(0) as OnnxTensor
            // Java 输出是嵌套基本类型数组（float[][][]），递归展平成 1D
            val prob = flattenFloats(result.value)
            val shape = result.info.shape        // [1,1,H,W] 实际尺寸
            val outW = shape[3].toInt()
            val outH = shape[2].toInt()
            // scale = 概率图高度 / 原图高度（用于把行带坐标映回原图）
            return DetResult(outW, outH, prob, outH.toDouble() / image.height)
        }
    }

    /** det 缩放：最小边 → 736，长宽取整到 32 的倍数。返回 (图, 原图/新图 比例) */
    private fun detResize(image: OcrImage): Pair<OcrImage, Double> {
        val h = image.height
        val w = image.width
        val limit = 736.0
        val ratio = if (minOf(h, w) < limit) {
            limit / minOf(h, w)
        } else {
            1.0
        }
        var resizeH = (h * ratio).toInt()
        var resizeW = (w * ratio).toInt()
        resizeH = ((resizeH + 16) / 32) * 32
        resizeW = ((resizeW + 16) / 32) * 32
        if (resizeH <= 0) resizeH = 32
        if (resizeW <= 0) resizeW = 32
        return image.resize(resizeW, resizeH) to resizeH.toDouble() / h
    }

    /**
     * 运行 rec，识别一行文字。
     * 预处理与 RapidOCR 完全一致：高 48、宽按比例（上限 320）、右侧补零。
     */
    fun runRec(image: OcrImage): String {
        val h = 48
        val maxW = 320
        val ratio = image.width.toDouble() / image.height
        var w = (h * ratio).toInt()
        if (w < 1) w = 1
        if (w > maxW) w = maxW

        val resized = image.resize(w, h)
        val ch = w * h
        val input = FloatArray(3 * h * maxW) // 右侧补零
        val pixels = resized.pixels
        for (i in pixels.indices) {
            val v = pixels[i]
            val r = (v shr 16 and 0xFF) / 255f
            val g = (v shr 8 and 0xFF) / 255f
            val b = (v and 0xFF) / 255f
            input[i] = (r - 0.5f) / 0.5f
            input[ch + i] = (g - 0.5f) / 0.5f
            input[2 * ch + i] = (b - 0.5f) / 0.5f
        }

        val tensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(input),
            longArrayOf(1L, 3L, h.toLong(), maxW.toLong())
        )
        tensor.use {
            val result = recSession.run(mapOf("x" to it)).get(0) as OnnxTensor
            val flat = flattenFloats(result.value)
            val shape = result.info.shape        // [1, T, 6625]
            val t = shape[1].toInt()
            val classes = shape[2].toInt()
            // 贪心解码：argmax → 去 blank(0) → 去相邻重复 → 查表
            val sb = StringBuilder()
            var prev = -1
            for (i in 0 until t) {
                var best = 0
                var bestV = -Float.MAX_VALUE
                val base = i * classes
                for (j in 0 until classes) {
                    val v = flat[base + j]
                    if (v > bestV) {
                        bestV = v
                        best = j
                    }
                }
                if (best == 0) {
                    prev = -1
                    continue
                }
                if (best == prev) continue
                sb.append(charTable.getOrElse(best) { "" })
                prev = best
            }
            return sb.toString()
        }
    }

    /** onnxruntime Java 输出是嵌套基本类型数组，递归展平成 FloatArray */
    private fun flattenFloats(v: Any?): FloatArray {
        val out = ArrayList<Float>(65536)
        flattenInto(v, out)
        return FloatArray(out.size) { out[it] }
    }

    private fun flattenInto(v: Any?, out: ArrayList<Float>) {
        when (v) {
            is Float -> out.add(v)
            is FloatArray -> for (x in v) flattenInto(x, out)
            is Array<*> -> for (x in v) flattenInto(x, out)
            else -> error("意外的张量元素类型: ${v?.javaClass}")
        }
    }

    override fun close() {
        detSession.close()
        recSession.close()
        env.close()
    }

    companion object {
        /**
         * 从 rec 模型元数据读取字符表。
         *
         * 实测（重要）：元数据 `character` 是「每行一个字符」，
         * 但**第一行是一个孤立的引号 `'`**（历史格式残渣）。
         * RapidOCR 的做法是把它也放进字符表（index 1 = "'"），
         * 模型几乎不会预测到它，所以输出仍然是干净的。
         * 这里**原样复刻**，保证与桌面端逐位一致。
         */
        fun loadCharTable(metaValue: String): Array<String> {
            val lines = metaValue.split("\n")
            val table = ArrayList<String>(lines.size + 2)
            table.add("blank")
            table.addAll(lines)
            table.add(" ")
            return table.toTypedArray()
        }
    }
}
