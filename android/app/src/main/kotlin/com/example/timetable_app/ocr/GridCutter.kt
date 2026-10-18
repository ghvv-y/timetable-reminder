package com.example.timetable_app.ocr

/**
 * 表格网格检测：移植自桌面端 tools/recognize_schedule.py 的 find_grid_lines。
 *
 * 算法（已验证有效）：
 *   1. 灰度图中「接近灰色且偏暗」的像素视为线条（max-min < 26 且 gray < 232）
 *   2. 行方向投影，连续超过 H_TOL 的位置聚成横线；同理竖线
 *   3. 横线只保留「间距规整」的那一段（排除底部课程清单表）
 *   4. 竖线用等宽假设剔除伪线（彩色格子边缘）
 *
 * 阈值与 Python 端一致：H_TOL=0.60, V_TOL=0.55, 间距容差 35%, 等宽容差 12%。
 */
object GridCutter {

    const val H_TOL = 0.60
    const val V_TOL = 0.55

    data class Grid(val ys: List<Int>, val xs: List<Int>) {
        val rows: Int get() = ys.size - 1
        val cols: Int get() = xs.size - 1
    }

    fun find(image: OcrImage): Grid {
        val gray = image.toGray()
        val lineish = BooleanArray(gray.size)

        // 逐像素判定「是否像线」：彩度低且偏暗
        for (i in gray.indices) {
            val v = image.pixels[i]
            val r = (v shr 16) and 0xFF
            val g = (v shr 8) and 0xFF
            val b = v and 0xFF
            val mx = maxOf(r, maxOf(g, b))
            val mn = minOf(r, minOf(g, b))
            lineish[i] = (mx - mn) < 26 && gray[i] < 232
        }

        val h = image.height
        val w = image.width

        // ---- 横线 ----
        val rowRatios = DoubleArray(h)
        for (y in 0 until h) {
            var sum = 0
            for (x in 0 until w) if (lineish[y * w + x]) sum++
            rowRatios[y] = sum.toDouble() / w
        }
        var ysAll = runs(rowRatios, H_TOL)
        if (ysAll.isEmpty()) return Grid(emptyList(), emptyList())

        // 只保留间距规整的那一段
        var ys = ysAll
        if (ysAll.size >= 4) {
            val gaps = IntArray(ysAll.size - 1) { i -> ysAll[i + 1] - ysAll[i] }
            val base = median(gaps)
            var best = mutableListOf<Int>()
            var cur = mutableListOf<Int>(ysAll[0])
            for (i in gaps.indices) {
                if (kotlin.math.abs(gaps[i] - base) <= base * 0.35) {
                    cur.add(ysAll[i + 1])
                } else {
                    if (cur.size > best.size) best = cur
                    cur = mutableListOf(ysAll[i + 1])
                }
            }
            if (cur.size > best.size) best = cur
            if (best.size >= 3) ys = best
        }
        if (ys.size < 3) return Grid(ys, emptyList())

        // ---- 竖线（只扫描横线范围内的区域）----
        val top = ys.first()
        val bottom = ys.last()
        val colRatios = DoubleArray(w)
        for (x in 0 until w) {
            var sum = 0
            for (y in top..bottom) if (lineish[y * w + x]) sum++
            colRatios[x] = sum.toDouble() / (bottom - top + 1)
        }
        var xs = runs(colRatios, V_TOL)
        xs = xs.filter { it > 20 && it < w - 20 }.toMutableList()
        xs = regularize(xs)

        return Grid(ys, xs)
    }

    /** 连续超过阈值的区间，取中点作为线位置 */
    private fun runs(ratios: DoubleArray, th: Double): MutableList<Int> {
        val out = mutableListOf<Int>()
        var inRun = false
        var start = 0
        for (i in ratios.indices) {
            val v = ratios[i] > th
            if (v && !inRun) {
                start = i
                inRun = true
            } else if (!v && inRun) {
                out.add((start + i - 1) / 2)
                inRun = false
            }
        }
        if (inRun) out.add((start + ratios.size - 1) / 2)
        return out
    }

    /** 等宽假设剔除伪线（与 Python regularize 一致） */
    private fun regularize(xs: MutableList<Int>): MutableList<Int> {
        if (xs.size < 3) return xs
        val gaps = IntArray(xs.size - 1) { i -> xs[i + 1] - xs[i] }
        val big = gaps.filter { it > 40 }
        val med = median(if (big.isEmpty()) gaps else big.toIntArray()).toDouble()
        val keep = mutableListOf(xs[0])
        for (x in xs.drop(1)) {
            if (x - keep.last() > med * (1 - 0.12)) keep.add(x)
        }
        return keep
    }

    private fun median(arr: IntArray): Int {
        val s = arr.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
