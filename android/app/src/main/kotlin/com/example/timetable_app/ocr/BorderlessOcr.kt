// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
package com.example.timetable_app.ocr

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 无框线课表识别（对应桌面端 tools/_lineless 里验证过的算法）
 *
 * 为什么需要它：
 *   现有 GridCutter 靠「检测黑色表格线」切格。教务系统网页版的课表
 *   是**彩色色块拼接、没有绘制竖线**——实测竖线检测返回 0 条，
 *   整条管线直接失败。
 *
 * 这里换成「先整图 OCR 拿文本框，再用课表自带的两个天然锚点排版」：
 *   列锚点：星期一…星期日的 x 中心
 *   行锚点：第(HH:MM-HH:MM) 的 y 中心
 * 每个文字块按中心点落进 (节次, 星期, 子槽) 三元组。
 *
 * 子槽位（slot）意义：
 *   教务系统常把同一时段两门课压缩成半列宽并排显示。
 *   slot0 = 列中心（当天第 1 门），slot1 = 相邻列中点（当天第 2 门）。
 *   实测这样能把「周一 形势与政策 / 专业导论」正确分开。
 */
object BorderlessOcr {

    private const val TAG = "BorderlessOcr"

    /** 一个文字块（原图坐标） */
    data class Box(
        val x0: Float, val y0: Float, val x1: Float, val y1: Float,
        val text: String,
    ) {
        val cx: Float get() = (x0 + x1) / 2f
        val cy: Float get() = (y0 + y1) / 2f
    }

    /** 裁剪区域 */
    data class Region(val x0: Int, val y0: Int, val x1: Int, val y1: Int, val why: String)

    private val WEEKDAY_RE = Regex("星期([一二三四五六日天])")
    private val TIME_RE = Regex("""第?\s*[(（]?\s*(\d{1,2})\s*[:：]\s*(\d{2})\s*[-—–~～]\s*(\d{1,2})\s*[:：]\s*(\d{2})""")

    private val DAY_INDEX = mapOf(
        '一' to 1, '二' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '日' to 7, '天' to 7,
    )
    private val DAY_NAMES = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

    // ------------------------------------------------------------------
    // 一、整图 OCR：把图片变成一堆带坐标的文字块
    // ------------------------------------------------------------------

    /**
     * 整图识别。
     *
     * 做法：det 概率图 -> 行带投影 -> 每个行带内按横向空白切成若干块 -> 逐块 rec。
     * 这样比「逐格识别」通用：不需要事先知道格子在哪里。
     */
    fun ocrBoxes(engine: OcrEngine, image: OcrImage): List<Box> {
        val det = engine.runDet(image)
        val w = det.width
        val h = det.height

        // 1) 行带：按行统计「有墨迹的列占比」
        val rowRatio = FloatArray(h)
        for (y in 0 until h) {
            var cnt = 0
            val base = y * w
            for (x in 0 until w) {
                if (det.prob[base + x] > DET_THRESH) cnt++
            }
            rowRatio[y] = cnt.toFloat() / w
        }

        val bands = ArrayList<Pair<Int, Int>>()
        var inBand = false
        var start = 0
        for (y in 0 until h) {
            val on = rowRatio[y] > BAND_RATIO
            if (on && !inBand) {
                start = y; inBand = true
            } else if (!on && inBand) {
                if (y - start >= MIN_BAND_H) bands.add(Pair(start, y))
                inBand = false
            }
        }
        if (inBand && h - start >= MIN_BAND_H) bands.add(Pair(start, h))

        // 2) 每个行带内部按横向空白切块
        val out = ArrayList<Box>()
        for ((bs, be) in bands) {
            // 该行带里每一列是否有墨迹
            val colInk = BooleanArray(w)
            for (y in bs until be) {
                val base = y * w
                for (x in 0 until w) {
                    if (det.prob[base + x] > DET_THRESH) colInk[x] = true
                }
            }

            var x = 0
            while (x < w) {
                if (!colInk[x]) { x++; continue }
                var end = x
                var gap = 0
                var k = x
                while (k < w) {
                    if (colInk[k]) { end = k; gap = 0 } else if (++gap > X_GAP) break
                    k++
                }
                val segW = end - x + 1
                if (segW >= MIN_SEG_W) {
                    // 坐标换回原图
                    val ox0 = (x / det.scale).toInt()
                    val ox1 = ((end + 1) / det.scale).toInt()
                    val oy0 = (bs / det.scale).toInt()
                    val oy1 = ((be) / det.scale).toInt()
                    val lineH = max(oy1 - oy0, 4)
                    // 上下外扩：不扩的话 rec 会因压得太扁而输出空白（实测）
                    val padY = (lineH * 0.8).toInt().coerceAtLeast(3)
                    val px0 = (ox0 - padY * 2).coerceAtLeast(0)
                    val px1 = (ox1 + padY * 2).coerceAtMost(image.width)
                    val py0 = (oy0 - padY).coerceAtLeast(0)
                    val py1 = (oy1 + padY).coerceAtMost(image.height)
                    if (px1 - px0 > 3 && py1 - py0 > 3) {
                        val text = engine.runRec(image.crop(px0, py0, px1, py1)).trim()
                        if (text.isNotEmpty()) {
                            out.add(Box(ox0.toFloat(), oy0.toFloat(), ox1.toFloat(), oy1.toFloat(), text))
                        }
                    }
                }
                x = end + 1
            }
        }
        Log.i(TAG, "整图 OCR：${out.size} 个文字块（行带 ${bands.size}）")
        return out
    }

    // ------------------------------------------------------------------
    // 二、自动找表格区域
    // ------------------------------------------------------------------

    fun findTableRegion(boxes: List<Box>, imgW: Int, imgH: Int): Region? {
        val headers = boxes.filter {
            WEEKDAY_RE.containsMatchIn(it.text) && (it.x1 - it.x0) < imgW * 0.12f
        }
        val times = boxes.filter { TIME_RE.containsMatchIn(it.text) }
        if (headers.size < 3 || times.size < 2) return null

        // 表头取 y 最集中的一组
        val hdrY = headers.map { it.y0 }.sorted()[headers.size / 2]
        val hdr = headers.filter { abs(it.y0 - hdrY) < 60 }
        if (hdr.size < 3) return null

        val x0 = min(hdr.minOf { it.x0 }, times.minOf { it.x0 })
        val x1 = hdr.maxOf { it.x1 }
        val y0 = min(hdr.minOf { it.y0 }, times.minOf { it.y0 })
        val y1 = times.maxOf { it.y1 }

        val padX = ((x1 - x0) * 0.01f).toInt() + 6
        val padY = ((y1 - y0) * 0.02f).toInt() + 6
        val rx0 = (x0 - padX).toInt().coerceAtLeast(0)
        val ry0 = (y0 - padY).toInt().coerceAtLeast(0)
        val rx1 = (x1 + padX).toInt().coerceAtMost(imgW)
        val ry1 = (y1 + padY).toInt().coerceAtMost(imgH)
        if (rx1 - rx0 < imgW * 0.2 || ry1 - ry0 < imgH * 0.15) return null

        return Region(rx0, ry0, rx1, ry1,
            "语义锚点（表头 ${hdr.size} / 时间 ${times.size}）")
    }

    // ------------------------------------------------------------------
    // 三、锚点分格
    // ------------------------------------------------------------------

    /** 一天的锚点 */
    private data class DayAnchor(val day: Int, val cx: Float)

    /** 定位结果：星期索引 + 子槽 */
    private data class Spot(val day: Int, val slot: Int)

    private fun locate(cx: Float, anchors: List<DayAnchor>): Spot? {
        if (anchors.isEmpty()) return null

        var bestDay = -1
        var bestDist = Float.MAX_VALUE
        anchors.forEach {
            val d = abs(cx - it.cx)
            if (d < bestDist) { bestDist = d; bestDay = it.day }
        }

        var midDay = -1
        var midDist = Float.MAX_VALUE
        for (i in 0 until anchors.size - 1) {
            val mx = (anchors[i].cx + anchors[i + 1].cx) / 2f
            val d = abs(cx - mx)
            if (d < midDist) { midDist = d; midDay = anchors[i].day }
        }

        // 只有明显更靠近中点时才算「压缩列右半」
        if (midDay >= 0 && midDist < bestDist * 0.6f) return Spot(midDay, 1)
        return Spot(bestDay, 0)
    }

    /**
     * 完整识别：图片 -> 网格 JSON
     *
     * 返回结构（Dart 侧直接能用）：
     * {
     *   "rows": ["08:00-08:45", ...],
     *   "days": [1,2,3,4,5,6,7],
     *   "grid": [[["课名","教师","7-8周",...], [...]], ...]  // grid[row][dayIndex][slot]
     *   "region": {...}, "stats": {...}
     * }
     */
    fun recognize(engine: OcrEngine, image: OcrImage): String {
        val started = System.currentTimeMillis()

        // 1) 先整图 OCR 一次（用于找表格区域）
        val fullBoxes = ocrBoxes(engine, image)
        val region = findTableRegion(fullBoxes, image.width, image.height)

        // 2) 有区域就裁出来重新 OCR（去掉浏览器工具栏等干扰）
        val work: OcrImage
        val boxes: List<Box>
        if (region != null) {
            work = image.crop(region.x0, region.y0, region.x1, region.y1)
            boxes = ocrBoxes(engine, work)
        } else {
            work = image
            boxes = fullBoxes
        }

        // 3) 列锚点：星期表头
        val headerBoxes = boxes.filter {
            val m = WEEKDAY_RE.find(it.text) ?: return@filter false
            m.range.first == 0 && m.range.last == it.text.length - 1 &&
                (it.x1 - it.x0) < work.width * 0.12f
        }
        val anchorMap = LinkedHashMap<Int, MutableList<Float>>()
        for (b in headerBoxes) {
            val c = WEEKDAY_RE.find(b.text)?.groupValues?.get(1)?.firstOrNull() ?: continue
            val day = DAY_INDEX[c] ?: continue
            anchorMap.getOrPut(day) { ArrayList() }.add(b.cx)
        }
        if (anchorMap.size < 4) {
            throw IllegalStateException(
                "没找到星期表头（只识别到 ${anchorMap.size} 个）。" +
                    "请确认截图里包含「星期一…星期日」这一行"
            )
        }
        val anchors = anchorMap.map { DayAnchor(it.key, it.value.average().toFloat()) }
            .sortedBy { it.cx }

        // 4) 行锚点：时间栏
        val timeBoxes = boxes.filter {
            TIME_RE.containsMatchIn(it.text) && it.x1 <= anchors.first().cx
        }
        if (timeBoxes.size < 3) {
            throw IllegalStateException(
                "没找到时间栏（只识别到 ${timeBoxes.size} 个）。请确认截图里包含左侧的节次时间"
            )
        }
        val timeRows = timeBoxes.map { b ->
            val m = TIME_RE.find(b.text)!!
            val label = String.format(
                "%02d:%s-%02d:%s",
                m.groupValues[1].toInt(), m.groupValues[2],
                m.groupValues[3].toInt(), m.groupValues[4]
            )
            Pair(label, b.cy)
        }.sortedBy { it.second }

        // 5) 落格
        val grid = Array(timeRows.size) {
            Array(anchors.size) { arrayListOf<ArrayList<String>>(ArrayList(), ArrayList()) }
        }
        var placed = 0
        var slot1 = 0

        for (b in boxes) {
            if (b.text.isEmpty()) continue
            // 跳过时间栏本身
            if (TIME_RE.containsMatchIn(b.text) && b.x1 <= anchors.first().cx) continue

            val ri = rowIndex(timeRows, b.cy) ?: continue
            val spot = locate(b.cx, anchors) ?: continue
            val ci = anchors.indexOfFirst { it.day == spot.day }
            if (ci < 0) continue
            grid[ri][ci][spot.slot].add(b.text)
            placed++
            if (spot.slot == 1) slot1++
        }

        // 6) 输出 JSON
        val root = JSONObject()
        val rowsArr = JSONArray()
        timeRows.forEach { rowsArr.put(it.first) }
        root.put("rows", rowsArr)

        val daysArr = JSONArray()
        anchors.forEach { daysArr.put(it.day) }
        root.put("days", daysArr)

        val gridArr = JSONArray()
        for (r in grid.indices) {
            val rowArr = JSONArray()
            for (c in grid[r].indices) {
                val cellArr = JSONArray()
                for (s in 0..1) {
                    val slotArr = JSONArray()
                    grid[r][c][s].forEach { slotArr.put(it) }
                    cellArr.put(slotArr)
                }
                rowArr.put(cellArr)
            }
            gridArr.put(rowArr)
        }
        root.put("grid", gridArr)

        val statsObj = JSONObject()
        statsObj.put("boxes", boxes.size)
        statsObj.put("placed", placed)
        statsObj.put("slot1", slot1)
        statsObj.put("rows", timeRows.size)
        statsObj.put("days", anchors.size)
        statsObj.put("elapsedMs", System.currentTimeMillis() - started)
        if (region != null) {
            statsObj.put("region", "${region.x0},${region.y0} ${region.x1 - region.x0}x${region.y1 - region.y0}")
            statsObj.put("regionWhy", region.why)
        }
        root.put("stats", statsObj)

        Log.i(TAG, "无框线识别完成：$statsObj")
        return root.toString()
    }

    /** 用相邻时间锚点的中点做行边界 */
    private fun rowIndex(times: List<Pair<String, Float>>, cy: Float): Int? {
        if (times.size < 2) return if (times.isNotEmpty()) 0 else null
        for (i in times.indices) {
            val top = if (i == 0) times[0].second - (times[1].second - times[0].second) / 2
            else (times[i - 1].second + times[i].second) / 2
            val bottom = if (i == times.size - 1)
                times[i].second + (times[i].second - times[i - 1].second) / 2
            else (times[i].second + times[i + 1].second) / 2
            if (cy in top..bottom) return i
        }
        return null
    }

    private const val DET_THRESH = 0.3f
    private const val BAND_RATIO = 0.01f
    private const val MIN_BAND_H = 3
    private const val X_GAP = 4
    private const val MIN_SEG_W = 8
}
