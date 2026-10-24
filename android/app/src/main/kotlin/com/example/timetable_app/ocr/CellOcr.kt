// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app.ocr

/**
 * 逐格 OCR 管线：网格 → 每格切行 → 每行识别。
 *
 * 移植自桌面端 recognize_schedule.py 的 ocr_cells，
 * 并复刻 RapidOCR 的「小格跳过 det」规则：
 *   - 格子高度 ≤ 30px 或 宽高比 > 8 时，整格直接当一行喂 rec
 *   - 否则先用 det 找出行带，再逐行 rec
 *
 * 与桌面端的差异（刻意简化）：
 *   det 后处理不用轮廓 + unclip，改用「水平投影找行带」——
 *   课表文字都是水平排列，投影法更简单、更稳，还省去 pyclipper 依赖。
 */
object CellOcr {

    /** 空格子判定阈值（与 Python cell_is_blank 一致） */
    private const val BLANK_INK_RATIO = 0.004

    /** det 概率图阈值 */
    private const val DET_THRESH = 0.3f

    /** 行带判定：该行上有文字的概率像素占比 */
    private const val BAND_ROW_RATIO = 0.02

    /** 相邻行带在模型尺度下小于该距离则合并 */
    private const val BAND_MERGE_GAP = 10

    /** 结果：(行, 列) -> 该格从上到下的文字行 */
    fun ocrCells(
        engine: OcrEngine,
        image: OcrImage,
        grid: GridCutter.Grid
    ): Map<Pair<Int, Int>, List<String>> {
        val result = LinkedHashMap<Pair<Int, Int>, List<String>>()
        val ys = grid.ys
        val xs = grid.xs

        for (r in 0 until ys.size - 1) {
            for (c in 0 until xs.size - 1) {
                val x0 = xs[c] + 2
                val y0 = ys[r] + 2
                val x1 = xs[c + 1] - 1
                val y1 = ys[r + 1] - 1
                if (x1 <= x0 || y1 <= y0) continue

                val cell = image.crop(x0, y0, x1, y1)
                if (isBlank(cell)) continue

                val texts = recognizeCell(engine, cell)
                if (texts.isNotEmpty()) {
                    result[Pair(r, c)] = texts
                }
            }
        }
        return result
    }

    /**
     * 与 RapidOCR 相同的分派规则：小格 / 超宽格直接整格 rec，否则 det 分行。
     */
    private fun recognizeCell(engine: OcrEngine, cell: OcrImage): List<String> {
        val ratio = cell.width.toDouble() / cell.height
        if (cell.height <= 30 || ratio > 8) {
            val text = engine.runRec(cell).trim()
            return if (text.isEmpty()) emptyList() else listOf(text)
        }

        val det = engine.runDet(cell)
        val bands = findBands(det)
        if (bands.isEmpty()) {
            val text = engine.runRec(cell).trim()
            return if (text.isEmpty()) emptyList() else listOf(text)
        }

        val out = mutableListOf<String>()
        for ((by0, by1) in bands) {
            // det 带内用墨迹投影二次细分 —— det 给正确的大区域，
            // 墨迹给精确的行边界（单独用 det 或单独用墨迹都不稳）。
            val subBands = refineByInk(cell, by0, by1)
            for ((sy0, sy1, sx0, sx1) in subBands) {
                val lineH = sy1 - sy0
                val padY = (lineH * 0.8).toInt().coerceAtLeast(4)
                val py0 = (sy0 - padY).coerceAtLeast(0)
                val py1 = (sy1 + padY).coerceAtMost(cell.height)
                val padX = (padY * 2).coerceAtLeast(6)
                val px0 = (sx0 - padX).coerceAtLeast(0)
                val px1 = (sx1 + padX).coerceAtMost(cell.width)
                if (py1 <= py0 || px1 <= px0) continue

                val line = cell.crop(px0, py0, px1, py1)
                val text = engine.runRec(line).trim()
                if (text.isNotEmpty()) out.add(text)
            }
        }
        return out
    }

    /**
     * det 概率图行带（模型尺度）。只做水平投影和合并，
     * 不在这里做外扩和横向收缩 —— 那些在 recognizeCell 里按墨迹来。
     */
    private fun findBands(det: OcrEngine.DetResult): List<Pair<Int, Int>> {
        val h = det.height
        val w = det.width
        val rowRatio = DoubleArray(h)
        for (y in 0 until h) {
            var cnt = 0
            for (x in 0 until w) {
                if (det.prob[y * w + x] > DET_THRESH) cnt++
            }
            rowRatio[y] = cnt.toDouble() / w
        }
        val bands = mutableListOf<Pair<Int, Int>>()
        var inBand = false
        var start = 0
        for (y in 0 until h) {
            val on = rowRatio[y] > BAND_ROW_RATIO
            if (on && !inBand) {
                start = y
                inBand = true
            } else if (!on && inBand) {
                bands.add(Pair(start, y))
                inBand = false
            }
        }
        if (inBand) bands.add(Pair(start, h))

        val merged = mutableListOf<Pair<Int, Int>>()
        for (band in bands) {
            if (merged.isEmpty()) {
                merged.add(band)
                continue
            }
            val last = merged.last()
            if (band.first - last.second <= BAND_MERGE_GAP) {
                merged[merged.size - 1] = Pair(last.first, band.second)
            } else {
                merged.add(band)
            }
        }
        // 模型坐标 -> 原图坐标
        return merged.map { (s, e) ->
            Pair(
                (s / det.scale).toInt().coerceIn(0, Int.MAX_VALUE),
                ((e / det.scale).toInt() + 1)
            )
        }
    }

    /** 在 det 带的范围内用墨迹投影再分行，返回 [y0, y1, x0, x1]（原图坐标） */
    private fun refineByInk(cell: OcrImage, yTop: Int, yBottom: Int): List<InkBand> {
        val gray = cell.toGray()
        val w = cell.width
        val h = cell.height
        val y0c = yTop.coerceIn(0, h)
        val y1c = yBottom.coerceIn(0, h)
        if (y1c <= y0c) return emptyList()

        val rowRatio = DoubleArray(y1c - y0c)
        for (y in y0c until y1c) {
            var cnt = 0
            for (x in 0 until w) if (gray[y * w + x] < 180) cnt++
            rowRatio[y - y0c] = cnt.toDouble() / w
        }
        val rows = mutableListOf<Pair<Int, Int>>()
        var inBand = false
        var start = 0
        for (i in rowRatio.indices) {
            val on = rowRatio[i] > 0.005
            if (on && !inBand) {
                start = i
                inBand = true
            } else if (!on && inBand) {
                rows.add(Pair(start, i))
                inBand = false
            }
        }
        if (inBand) rows.add(Pair(start, rowRatio.size))

        return rows.map { (s, e) ->
            val sy0 = y0c + s
            val sy1 = y0c + e
            var x0 = w
            var x1 = 0
            for (y in sy0 until sy1.coerceAtMost(h)) {
                for (x in 0 until w) {
                    if (gray[y * w + x] < 180) {
                        if (x < x0) x0 = x
                        if (x > x1) x1 = x
                    }
                }
            }
            InkBand(sy0, sy1, if (x1 < x0) 0 else x0, if (x1 < x0) w else x1)
        }
    }

    private data class InkBand(val y0: Int, val y1: Int, val x0: Int, val x1: Int)

    /** 空白格判定：暗像素占比 < 0.004（阈值与 Python 端一致） */
    private fun isBlank(cell: OcrImage): Boolean {
        val gray = cell.toGray()
        var ink = 0
        for (g in gray) if (g < 215) ink++
        return ink.toDouble() / gray.size < BLANK_INK_RATIO
    }
}
