package com.example.timetable_app

import com.example.timetable_app.ocr.CellOcr
import com.example.timetable_app.ocr.GridCutter
import com.example.timetable_app.ocr.OcrEngine
import com.example.timetable_app.ocr.OcrImage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.InputStream

/**
 * 真实课表端到端识别测试。
 *
 * 用桌面端 onnxruntime 跑**和手机上完全相同的 Kotlin 代码与模型**，
 * 对真实课表图片（2940x2522）做完整管线：网格检测 → 逐格切行 → PP-OCR。
 *
 * 这是「手机端识别质量」在电脑上的预演 —— 这里跑出的数字，
 * 基本就是装到手机上会得到的数字。
 */
class OcrEngineTest {

    private fun asset(name: String): String {
        val candidates = listOf(
            "src/main/assets/ocr/$name",
            "android/app/src/main/assets/ocr/$name",
            "D:\\ruanjian\\TimetableApp\\android\\app\\src\\main\\assets\\ocr\\$name"
        )
        for (c in candidates) {
            if (File(c).exists()) return c
        }
        throw IllegalStateException("找不到模型文件 $name")
    }

    private fun loadImage(): OcrImage {
        val ppm = File("src/test/resources/timetable.ppm")
        require(ppm.exists()) { "找不到测试图片 ${ppm.absolutePath}" }
        // 手写 PPM(P6) 解析：安卓单测类路径里没有 javax.imageio
        File("src/test/resources/timetable.ppm").inputStream().use { input ->
            fun readToken(input: InputStream): String {
                val sb = StringBuilder()
                while (true) {
                    val b = input.read()
                    if (b == -1) break
                    val ch = b.toChar()
                    if (ch == '#' ) {
                        while (input.read() != '\n'.code) { /* skip comment */ }
                        continue
                    }
                    if (ch.isWhitespace()) {
                        if (sb.isNotEmpty()) break
                    } else {
                        sb.append(ch)
                    }
                }
                return sb.toString()
            }

            val magic = readToken(input)
            require(magic == "P6") { "不是 P6 PPM: $magic" }
            val w = readToken(input).toInt()
            val h = readToken(input).toInt()
            readToken(input) // maxval 255
            val px = IntArray(w * h)
            val buf = ByteArray(w * h * 3)
            var off = 0
            while (off < buf.size) {
                val n = input.read(buf, off, buf.size - off)
                if (n <= 0) break
                off += n
            }
            for (i in px.indices) {
                val r = buf[i * 3].toInt() and 0xFF
                val g = buf[i * 3 + 1].toInt() and 0xFF
                val b = buf[i * 3 + 2].toInt() and 0xFF
                px[i] = (r shl 16) or (g shl 8) or b
            }
            return OcrImage(w, h, px)
        }
    }

    @Test
    fun `网格检测与桌面端一致`() {
        val grid = GridCutter.find(loadImage())
        println("横线 ${grid.ys.size} 条: ${grid.ys}")
        println("竖线 ${grid.xs.size} 条: ${grid.xs}")
        assertEquals(14, grid.ys.size)
        assertEquals(8, grid.xs.size)
    }

    @Test
    fun `真实课表全量识别`() {
        OcrEngine(asset("ch_PP-OCRv3_det_infer.onnx"),
            asset("ch_PP-OCRv3_rec_infer.onnx")).use { engine ->
            val image = loadImage()
            val grid = GridCutter.find(image)
            val cells = CellOcr.ocrCells(engine, image, grid)

            println("共 ${cells.size} 个非空格:")
            val wd = arrayOf("", "周一", "周二", "周三", "周四", "周五", "周六", "周日")
            for ((k, v) in cells.toSortedMap(compareBy({ it.first }, { it.second }))) {
                println("  [行${k.first} ${wd.getOrElse(k.second) { "列${k.second}" }}] $v")
            }

            // ---- 时间栏（12 节必须全对）----
            val expected = listOf(
                "08:00" to "08:45", "08:50" to "09:35",
                "10:05" to "10:50", "10:55" to "11:40",
                "13:30" to "14:15", "14:20" to "15:05",
                "15:35" to "16:20", "16:25" to "17:10",
                "18:00" to "18:45", "18:50" to "19:35",
                "19:40" to "20:25", "20:30" to "21:15"
            )
            for (r in 0 until 12) {
                val texts = cells[Pair(r, 0)] ?: emptyList()
                val joined = texts.joinToString(" ")
                val (s, e) = expected[r]
                assertTrue(
                    "第${r + 1}节时间栏识别失败: $joined（应含 $s 和 $e）",
                    joined.contains(s) && joined.contains(e)
                )
            }

            // ---- 抽查关键课程词（整个课表范围内出现即可）----
            //
            // 注意：这里只做「全局存在性」检查。个别格子的行带几何
            // （如周一1-2节、体育格）还在调优，等稳定后再收紧到格级断言。
            val all = cells.values.flatten().joinToString("\n")
            for (kw in listOf("大学英语", "马克思主义基本原理",
                "工程图学", "黄怡凡")) {
                assertTrue("课表里应识别出「$kw」", all.contains(kw))
            }
        }
    }
}
