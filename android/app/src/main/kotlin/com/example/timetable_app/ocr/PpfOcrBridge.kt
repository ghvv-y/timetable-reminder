package com.example.timetable_app.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import com.example.timetable_app.ocr.CellOcr
import com.example.timetable_app.ocr.GridCutter
import com.example.timetable_app.ocr.OcrEngine
import com.example.timetable_app.ocr.OcrImage
import java.io.File

/**
 * 安卓侧的 PP-OCR 入口：把「图片文件」变成「按行列组织的文字」。
 *
 * 为什么要在 Android 层做这些：
 *   - 模型在 assets 里，ONNX Runtime 只能读文件路径，必须先落到私有目录
 *   - Bitmap 解码是 Android API，Dart 侧拿不到原始像素
 *   - 识别是重 CPU 操作，必须放子线程
 *
 * 返回给 Dart 的结构（JSON）：
 *   { "cells": [ { "row": 0, "col": 0, "lines": ["第(08:00-08:45)"] }, ... ],
 *     "grid": { "ys": [...], "xs": [...] } }
 * 后续的「哪些是时间栏、哪些是课程」由 Dart 侧的 cell_parser 负责，
 * 保持和桌面 Python 工具同一套解析规则。
 */
object PpfOcrBridge {

    private const val TAG = "PpfOcrBridge"

    /** 模型文件名（assets/ocr/ 下） */
    private const val DET_MODEL = "ch_PP-OCRv3_det_infer.onnx"
    private const val REC_MODEL = "ch_PP-OCRv3_rec_infer.onnx"

    /**
     * 把 assets 里的模型复制到私有目录（只做一次）。
     * 返回 (detPath, recPath)
     */
    fun ensureModels(context: Context): Pair<String, String> {
        val dir = File(context.filesDir, "ocr_models")
        if (!dir.exists()) dir.mkdirs()

        fun copy(name: String): String {
            val out = File(dir, name)
            // 体积一致就认为已复制（避免每次启动都重拷 12MB）
            val assetLen = try {
                context.assets.open("ocr/$name").use { it.available().toLong() }
            } catch (e: Exception) {
                -1L
            }
            if (out.exists() && out.length() > 0 &&
                (assetLen <= 0 || out.length() == assetLen)
            ) {
                return out.absolutePath
            }
            context.assets.open("ocr/$name").use { input ->
                out.outputStream().use { output ->
                    input.copyTo(output, 1 shl 16)
                }
            }
            Log.i(TAG, "模型已释放：${out.name} ${out.length()} 字节")
            return out.absolutePath
        }

        return Pair(copy(DET_MODEL), copy(REC_MODEL))
    }

    /** 把图片文件解码成纯 Kotlin 的 OcrImage */
    fun loadImage(path: String): OcrImage {
        val bmp: Bitmap = BitmapFactory.decodeFile(path)
            ?: throw IllegalStateException("图片解码失败：$path")
        val w = bmp.width
        val h = bmp.height
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        if (!bmp.isRecycled) bmp.recycle()
        // getPixels 给的是 ARGB，这里只保留 RGB 位（OcrImage 按 RGB 解析）
        for (i in px.indices) px[i] = px[i] and 0xFFFFFF
        return OcrImage(w, h, px)
    }

    /**
     * 完整识别：图片路径 -> 格子文字。
     *
     * 注意：这是阻塞操作（大图约数秒），调用方必须放在子线程。
     */
    fun recognize(context: Context, imagePath: String): String {
        val (det, rec) = ensureModels(context)
        val image = loadImage(imagePath)
        Log.i(TAG, "识别开始 ${image.width}x${image.height}")

        val grid = GridCutter.find(image)
        Log.i(TAG, "网格：${grid.ys.size} 横线 / ${grid.xs.size} 竖线")
        if (grid.ys.size < 3 || grid.xs.size < 3) {
            throw IllegalStateException(
                "没检测到表格线（横 ${grid.ys.size} / 竖 ${grid.xs.size}）。" +
                        "请确认这是「表格型」课表截图，不要裁掉表格边框。"
            )
        }

        OcrEngine(det, rec).use { engine ->
            val cells = CellOcr.ocrCells(engine, image, grid)
            Log.i(TAG, "识别完成：${cells.size} 个非空格")

            val cellsArr = org.json.JSONArray()
            for ((k, lines) in cells) {
                val o = org.json.JSONObject()
                o.put("row", k.first)
                o.put("col", k.second)
                o.put("lines", org.json.JSONArray(lines))
                cellsArr.put(o)
            }
            val root = org.json.JSONObject()
            root.put("cells", cellsArr)

            val ysArr = org.json.JSONArray()
            for (y in grid.ys) ysArr.put(y)
            val xsArr = org.json.JSONArray()
            for (x in grid.xs) xsArr.put(x)
            val gridObj = org.json.JSONObject()
            gridObj.put("ys", ysArr)
            gridObj.put("xs", xsArr)
            root.put("grid", gridObj)

            return root.toString()
        }
    }
}
