"""课表识别 —— 逐格 OCR 版（v3，最终方案）

与前两版的根本区别：

    v1  全图 OCR 一次 -> 按坐标把文本块分配到推测的列/行
        （列边界靠表头推算，容易错）

    v2  全图 OCR 一次 + 格线定位
        （列判对了，但同一格子上下堆两门课时仍会串行）

    v3  先用格线把图像切成格子 -> **每个格子单独 OCR**
        （格子内不可能混入别格内容，不需要任何归属/聚类/拆分规则）

为什么要逐格：
    实测本机课表有 12 行 × 7 列 = 84 格，其中约 20 格有内容。
    全图 OCR 时，OCR 引擎会把相邻格子的文字当成一个文本块（因为它按行扫描），
    之后再怎么按坐标拆都容易错。逐格识别从根本上避免这个问题。

速度：
    全图 OCR 约 12 秒；逐格只处理有内容的格子（约 20 个），
    单个小格识别很快，总耗时相当。

输出：
    courses.json / period_times.json
"""

import json
import os
import re
import sys

import numpy as np
from PIL import Image

# ---------------- 可调配置 ----------------
#
# 这一块是**给别的学校适配用的**。如果你的课表格式和这里不同，
# 优先改这里的常量，通常不用动下面的解析函数。

# 「地点」关键词。
# 判定规则是「文本里出现这些字 → 认为是地点而不是课名」。
# 换成你学校的叫法即可，例如「座」「中心」「基地」「实训室」。
PLACE_WORDS = (
    "楼", "馆", "厅", "室", "操场", "报告", "园", "号",
)

# 地点常见前缀（校区名）。按你学校改，例如「北校区」「南苑」。
PLACE_PREFIXES = (
    "校本部", "本部", "北校", "南校", "东校", "西校", "学校",
)

# 星期表头。默认同时认「周一」和「星期一」。
WEEKDAY_HEADER = r"^[周星]\s*期?\s*([一二三四五六日天])$"

# ---------------- 正则 ----------------
RE_WEEKDAY = re.compile(WEEKDAY_HEADER)
WEEKDAY_MAP = {"一": 1, "二": 2, "三": 3, "四": 4,
               "五": 5, "六": 6, "日": 7, "天": 7}

RE_TIME_RANGE = re.compile(
    r"(\d{1,2})\s*[:：]\s*(\d{2})\s*[-—–~～至到]\s*(\d{1,2})\s*[:：]\s*(\d{2})")
RE_PERIOD_RANGE = re.compile(r"(\d{1,2})\s*[-—–~～至]\s*(\d{1,2})\s*节")
RE_PERIOD_ONE = re.compile(r"(\d{1,2})\s*节")
RE_WEEK_RANGE = re.compile(r"(\d{1,2})\s*[-—–~～至]\s*(\d{1,2})\s*周")
RE_WEEK_ONE = re.compile(r"第?\s*(\d{1,2})\s*周")
RE_TEACHER_STAR = re.compile(r"^[\u4e00-\u9fa5]{1,4}\s*[＊*·。、,\"”]+$")
RE_ROOM = re.compile(r"[A-Za-z]\d{1,3}\s*[-—]\s*\d{1,3}")
RE_HAS_CJK = re.compile(r"[\u4e00-\u9fa5]")

NOISE_WORDS = {
    "上午", "下午", "晚上", "学分", "课程属性", "课程类别", "考试类型",
    "修读方式", "选课状态", "选课限制说明", "教师", "地点", "时间",
    "课序号", "课程号", "课程名", "必修", "选修", "考查", "考试",
    "节次/时间", "未安排时间/地点课程清单",
}

H_TOL, V_TOL = 0.60, 0.55      # 线条检测阈值

# 空格子判定阈值
#
# 【踩过的坑】这个值曾经写成 0.015，导致**整个时间栏被跳过**——
# 时间栏文字占比约 0.0134，正好低于 0.015 被误判成空。
# 实测参考值：
#   真正空白的格子   约 0.0001
#   时间栏格子       约 0.0134
#   课程格子         约 0.02 ~ 0.06
# 取 0.004 能安全区分开。
BLANK_INK_RATIO = 0.004


# ---------------- 格线 ----------------
def header_columns(img_path, ys):
    """用星期表头的位置推导列边界。

    做法**只识别表头那一条**（不是整图），又快又准：
      1. 取第一条横线以上的区域作为表头带
      2. 单独 OCR 这条带，拿到每个「星期X」的左边界
      3. 相邻表头左边界的**中点**就是列分界

    为什么不用像素竖线：
        实测检测到的竖线在 x=859/1153/1448…，但真实列边界不在那里
        （那是色块边缘）。按它切会把「健康教育」（x=861）和
        「工程图学」（x=1008）都归到第 1 列，而后者其实属于第 2 列。
    """
    from rapidocr_onnxruntime import RapidOCR
    from PIL import Image

    im = Image.open(img_path).convert("RGB")
    band = np.asarray(im)[max(0, ys[0] - 120):ys[0], :]
    if band.size == 0:
        return []

    res, _ = RapidOCR()(band)
    heads = []
    for item in (res or []):
        box, text = item[0], item[1].strip()
        m = RE_WEEKDAY.match(text)
        if not m:
            continue
        x = min(p[0] for p in box)
        heads.append((WEEKDAY_MAP[m.group(1)], x))
    if len(heads) < 5:
        return []

    heads.sort(key=lambda h: h[1])
    seen, uniq = set(), []
    for wd, x in heads:
        if wd not in seen:
            seen.add(wd)
            uniq.append((wd, x))

    xs = [x for _, x in uniq]
    step = (xs[-1] - xs[0]) / (len(xs) - 1) if len(xs) > 1 else 295
    bounds = [xs[0] - step / 2]
    for i in range(len(xs) - 1):
        bounds.append((xs[i] + xs[i + 1]) / 2)
    bounds.append(xs[-1] + step / 2)
    return bounds          # 长度 = 列数 + 1


def band_columns(lineish, y0, y1, min_x, w, th=0.45):
    """在**某一个行带内**检测竖线，得到该行的列边界。

    为什么必须逐行带检测：
        这张课表**同一张表里有两套列布局** ——
          上午（1~6 节）：每列约 295px，与表头对齐
          下午（7~12 节）：每列约 147px，压缩了一半
        用一套全局列边界去切，必然有一半是错的。

    这正是「健康教育 / 工程图学」被并到同一列的原因。
    """
    sub = lineish[y0:y1, :]
    if sub.size == 0:
        return []
    ratios = sub.mean(axis=0)
    xs, inrun, start = [], False, 0
    for x in range(w):
        if ratios[x] > th and x > min_x:
            if not inrun:
                start, inrun = x, True
        elif inrun:
            xs.append((start + x - 1) // 2)
            inrun = False
    if inrun:
        xs.append((start + w - 1) // 2)
    return xs


def find_grid_lines(img_path):
    im = Image.open(img_path).convert("RGB")
    a = np.asarray(im).astype(np.int16)
    h, w, _ = a.shape

    gray = a.mean(axis=2)
    mx = a.max(axis=2)
    mn = a.min(axis=2)
    lineish = ((mx - mn) < 26) & (gray < 232)

    def runs(ratios, th):
        out, inrun, start = [], False, 0
        for i, v in enumerate(ratios):
            if v > th:
                if not inrun:
                    start, inrun = i, True
            elif inrun:
                out.append((start + i - 1) // 2)
                inrun = False
        if inrun:
            out.append((start + len(ratios) - 1) // 2)
        return out

    ys_all = runs(lineish.mean(axis=1), H_TOL)

    # 只保留「间距规整」的那一段（课表主体），排除底部清单表
    ys = ys_all
    if len(ys_all) >= 4:
        gaps = [ys_all[i + 1] - ys_all[i] for i in range(len(ys_all) - 1)]
        base = float(np.median(gaps))
        best, cur = [], [ys_all[0]]
        for i, g in enumerate(gaps):
            if abs(g - base) <= base * 0.35:
                cur.append(ys_all[i + 1])
            else:
                if len(cur) > len(best):
                    best = cur
                cur = [ys_all[i + 1]]
        if len(cur) > len(best):
            best = cur
        ys = best if len(best) >= 3 else ys_all

    top, bottom = ys[0], ys[-1]
    sub = lineish[top:bottom + 1, :]
    xs = runs(sub.mean(axis=0), V_TOL)
    xs = [x for x in xs if 20 < x < w - 20]
    xs = regularize(xs)
    return ys, xs


def regularize(xs, tol=0.12):
    """用等宽假设剔除伪线（彩色格子的边缘会被误判成竖线）"""
    if len(xs) < 3:
        return xs
    gaps = [xs[i + 1] - xs[i] for i in range(len(xs) - 1)]
    med = float(np.median([g for g in gaps if g > 40] or gaps))
    keep = [xs[0]]
    for x in xs[1:]:
        if x - keep[-1] > med * (1 - tol):
            keep.append(x)
    return keep


# ---------------- 格子切割 + 逐格 OCR ----------------
def cell_is_blank(arr):
    """判断格子是否空白（几乎没有任何墨迹）

    实测：真空白格子墨迹占比约 0.0001，时间栏约 0.0134，课程格 0.02~0.06。
    阈值取 0.004 —— 之前误写成 0.015，把整个时间栏都判成空了。
    """
    gray = arr.mean(axis=2)
    return float((gray < 215).mean()) < BLANK_INK_RATIO


def crop_to_ink(arr, pad=6):
    """把格子裁剪到「有内容」的范围，去掉四周大片空白。

    为什么需要：格子的实际宽度可能远大于里面的文字。
    实测时间栏格子宽 793px，而「第(08:00-08:45)」只占左边约 200px。
    若不裁剪，OCR 会在一大片空白里识别一小段小字，效果很差（甚至认不出）。
    """
    gray = arr.mean(axis=2)
    ink = gray < 215
    if not ink.any():
        return arr
    rows = np.where(ink.any(axis=1))[0]
    cols = np.where(ink.any(axis=0))[0]
    y0 = max(0, rows[0] - pad)
    y1 = min(arr.shape[0], rows[-1] + pad + 1)
    x0 = max(0, cols[0] - pad)
    x1 = min(arr.shape[1], cols[-1] + pad + 1)
    return arr[y0:y1, x0:x1]


def ocr_cells(img_path, ys, xs):
    """逐格 OCR：按全局格线切格子，每格单独识别。

    用全局列边界（实测能得到正确的星期归属），不逐个行带检测 ——
    实测逐行带检测会切得过碎、星期错位，反而更差。
    """
    from rapidocr_onnxruntime import RapidOCR
    from PIL import Image

    im = Image.open(img_path).convert("RGB")
    full = np.asarray(im)
    engine = RapidOCR()
    cells = {}
    scanned = 0

    for r in range(len(ys) - 1):
        y0, y1 = ys[r], ys[r + 1]
        for c in range(len(xs) - 1):
            x0, x1 = int(xs[c]), int(xs[c + 1])
            sub = full[y0 + 2:y1 - 1, x0 + 2:x1 - 1]
            if sub.size == 0:
                continue
            scanned += 1
            if cell_is_blank(sub):
                continue
            # 不裁剪、不放大：实测原样的格子区域识别率最好
            # （裁到文字边界再放大会把 '第(08:00-08:45)' 切成碎片）
            res, _ = engine(sub)
            texts = []
            for item in (res or []):
                t = item[1].strip()
                if t:
                    texts.append(t)
            if texts:
                cells[(r, c)] = texts

    print(f"共扫描 {scanned} 格，其中 {len(cells)} 格有内容")
    return cells


# ---------------- 时间栏 ----------------
def parse_times(cells, ncols):
    """最左列（列索引 0）解析成作息表"""
    out = []
    for r in range(max((k[0] for k in cells), default=-1) + 1):
        texts = cells.get((r, 0), [])
        for t in texts:
            m = RE_TIME_RANGE.search(t)
            if m:
                out.append({
                    "period": len(out) + 1,
                    "start": int(m.group(1)) * 60 + int(m.group(2)),
                    "end": int(m.group(3)) * 60 + int(m.group(4)),
                    "_row": r,
                })
                break
    return out


# ---------------- 格子 -> 课程 ----------------
def looks_like_place(t):
    """判断文字是否像「地点」而不是课名。

    为什么必须区分：课名写在第 1 节那行、教室写在第 2 节那行。
    如果第 2 行没有课名，我原来的逻辑会把「校本部3号教学楼3-310」
    当成课名，于是同一门课被拆成两条记录。
    """
    for pre in PLACE_PREFIXES:
        if t.startswith(pre):
            return True
    if any(k in t for k in PLACE_WORDS):
        return True
    if RE_ROOM.search(t):
        return True
    # 房间号：必须带字母或带横杠，否则纯数字（如课程编号 29 / 01）
    # 会被误判成地点。
    s = t.replace(" ", "")
    if re.match(r"^[A-Za-z]\d{1,4}([-—]\d{1,4})?$", s):
        return True
    if re.match(r"^\d{1,4}[-—]\d{1,4}$", s):
        return True
    return False


def parse_cell(texts, period_hint):
    """解析一个格子里的文本"""
    name = teacher = room = ""
    name_lines = []
    name_closed = False
    sw, ew = 1, 16
    sp = ep = None

    for t in texts:
        if t in NOISE_WORDS or RE_WEEKDAY.match(t) or t == "__supp__":
            continue

        m = RE_PERIOD_RANGE.search(t)
        if m:
            a, c = int(m.group(1)), int(m.group(2))
            sp, ep = min(a, c), max(a, c)
            continue

        m = RE_WEEK_RANGE.search(t)
        if m:
            a, c = int(m.group(1)), int(m.group(2))
            sw, ew = min(a, c), max(a, c)
            continue

        m = RE_WEEK_ONE.search(t)
        if m and "节" not in t and len(t) <= 6:
            n = int(m.group(1))
            if 1 <= n <= 30:
                sw = ew = n
            continue

        m = RE_PERIOD_ONE.search(t)
        if m and len(t) <= 6 and sp is None:
            n = int(m.group(1))
            if 1 <= n <= 12:
                sp = ep = n
            continue

        # 地点要先于课名判定
        if looks_like_place(t):
            room = (room + " " + t).strip() if room else t
            continue

        # 纯数字（29 / 01 / 08）是课程编号的后半段，不是地点。
        # 之前被当成了地点，出现「地点=29」这种结果。
        if re.match(r"^\d{1,3}$", t):
            name_lines.append(t)
            continue

        # 教师行：有的带星号（李帅*），有的不带（黄怡凡、张怡通）。
        # 只要出现教师行，课名就结束了 —— 否则教师名会被拼进课名。
        #
        # 【踩过的坑】「2~3 个汉字」这条规则必须要求**已经收集到课名**。
        # 否则像「体育」这种两字课名会被误判成人名，
        # 导致这门课变成「没有课名」而被合并进上一门课（体育整门丢失）。
        if RE_TEACHER_STAR.match(t) or (
                name_lines and re.match(r"^[\u4e00-\u9fa5]{2,3}$", t)):
            if not teacher:
                teacher = t
            name_closed = True
            continue

        # 课名可能是**连续多行**（如「工程图学B」+「（1）」+「_03」，
        # 或「人工智能与信息技术基础」+「A_05」）。
        # 只在遇到教师/周次/节次/地点之前收集。
        if not name_closed and (
                RE_HAS_CJK.search(t) or re.search(r"[A-Za-z0-9]", t)):
            name_lines.append(t)

    if name_lines:
        name = "".join(name_lines)

    # 只有地点/教师、没有课名也算有效（用作续行补充）
    if (not name or len(name) < 2) and not (room or teacher):
        return None

    return {
        "name": name, "teacher": teacher, "room": room,
        "startPeriod": sp if sp is not None else period_hint,
        "endPeriod": ep if ep is not None else period_hint,
        "startWeek": sw, "endWeek": ew,
    }


def split_paired_cell(texts):
    """把「一个格子里装了两门课」的文本拆开。

    什么时候会出现：
        这张表的**下午部分列宽只有上午的一半**（147px vs 295px），
        于是相邻两个星期的课都落进了同一个格子。
        也就是说：这一格里的第 1 门属于本列对应星期，**第 2 门属于下一个星期**。

    为什么能拆：
        OCR 是**按行**读的。两门课并排时，它会读成
            [课名A, 课名B, 编号A, 编号B, 教师A, 教师B, 周次A, 周次B, ...]
        也就是**成对交替**。实测：
            ['形势与政策','专业导论','29','01','孙兴昌','孙昱楠','9-11周','3-5周']
        所以取奇数位和偶数位就能还原成两门课。

    返回 [(文本列表, 星期偏移), ...]；星期偏移 0 表示本列，1 表示下一列。
    """
    if len(texts) < 4:
        return [(texts, 0)]
    # 判据：格子里出现 ≥2 个周次范围 或 ≥2 个节次范围。
    # 这是最稳的判据；试过的其他判据（数教师、看前两项像不像课名）
    # 都会在「体育」「高等数学A(1)_04」这类文本上误判。
    weeks = sum(1 for t in texts
                if RE_WEEK_RANGE.search(t) or RE_WEEK_ONE.search(t))
    periods = sum(1 for t in texts if RE_PERIOD_RANGE.search(t))
    if weeks < 2 and periods < 2:
        return [(texts, 0)]
    if len(texts) % 2 != 0:
        return [(texts, 0)]
    return [(texts[0::2], 0), (texts[1::2], 1)]


def build_courses(cells, periods):
    """把有内容的格子转成课程。

    【关键】课表里一门课常占多个格子行：
        `1-2节` 的课，课名写在第 1 节那行，教室写在第 2 节那行。
    所以必须**把同一列里连续的格子按顺序拼起来**，
    而不是每个格子当一门课。

    做法（逐列处理）：
        按行号从小到大遍历该列的内容格子：
          - 若该格有课名 -> 开启一门新课
          - 若该格没有课名（只是教室/教师/周次的续行）
            -> 并入当前这门课，并扩展它的节次范围
    """
    if not periods:
        return []
    row2period = {p["_row"]: p["period"] for p in periods}

    ncols = max((k[1] for k in cells), default=0)
    courses = []

    for c in range(1, ncols + 1):
        rows = sorted(r for (r, cc) in cells if cc == c)
        current = None
        for r in rows:
            texts = cells[(r, c)]
            period = row2period.get(r)
            if period is None:
                continue

            # 一个格子可能装了两门课（下午列宽只有一半），先拆开。
            #
            # 星期映射：
            #   普通行（一格一门课）  星期 = 列号
            #   压缩行（一格两门课）  星期 = 2×列号 - 1 + 偏移
            # 推导：压缩行 7 门课挤进 3.5 个格子里
            #   第1格 → 周一,周二   第2格 → 周三,周四
            #   第3格 → 周五,周六   第4格 → 周日
            parts = split_paired_cell(texts)
            compressed = len(parts) > 1
            for part, offset in parts:
                # 【必须夹在 1..7】公式是 2×列号-1+偏移。列号大时会算出
                # 8 / 13 / 14 这类非法星期（例：c=7 且 offset=1 → 14）。
                # 越界的星期会让 App 课表渲染出错，提醒也永远不触发。
                wd = (2 * c - 1 + offset) if compressed else c
                wd = max(1, min(7, wd))
                info = parse_cell(part, period)

                # 没有课名 = 本门课的续行（只有教室/教师），并入上一门课。
                # 【曾经的 bug】这里没先判断「无课名」，于是续行被当成新课，
                # 产生一堆名字是「A202」「收本3号数子按3-310」的假课程。
                if info is None or not info["name"]:
                    if current is not None:
                        supp = info or parse_cell(["__supp__"] + part, period)
                        if supp:
                            if not current["room"] and supp["room"]:
                                current["room"] = supp["room"]
                            if not current["teacher"] and supp["teacher"]:
                                current["teacher"] = supp["teacher"]
                            if supp["startWeek"] != 1 or supp["endWeek"] != 16:
                                current["startWeek"] = supp["startWeek"]
                                current["endWeek"] = supp["endWeek"]
                            # 续行里若明写了节次（如「7-8节」），用它修正范围。
                            # 之前漏了这一步，出现「形势与政策 第7-7节」
                            # （实际是 7-8 节）。
                            pm = RE_PERIOD_RANGE.search(" ".join(part))
                            if pm:
                                a, b = int(pm.group(1)), int(pm.group(2))
                                current["startPeriod"] = min(
                                    current["startPeriod"], min(a, b))
                                current["endPeriod"] = max(
                                    current["endPeriod"], max(a, b))
                                current["_explicitPeriod"] = True
                            elif not current.get("_explicitPeriod"):
                                current["endPeriod"] = max(
                                    current["endPeriod"], period)
                    continue

                # 同名且节次紧邻 -> 视为同一门课的续行；否则另起一门。
                # 例如周五第 1-2 节和第 5-6 节都叫「高等数学A(1)_04」，
                # 但它们是两门不同的课，不能被合并成「第1-6节」。
                same = (current is not None
                        and info["name"] == current["name"]
                        and period == current["endPeriod"] + 1)

                if same:
                    if not current["room"] and info["room"]:
                        current["room"] = info["room"]
                    if not current["teacher"] and info["teacher"]:
                        current["teacher"] = info["teacher"]
                    if (current["startWeek"] == 1 and current["endWeek"] == 16
                            and (info["startWeek"] != 1
                                 or info["endWeek"] != 16)):
                        current["startWeek"] = info["startWeek"]
                        current["endWeek"] = info["endWeek"]
                    if not current.get("_explicitPeriod"):
                        current["endPeriod"] = max(current["endPeriod"], period)
                else:
                    info["weekday"] = wd
                    if info["endPeriod"] < info["startPeriod"]:
                        info["startPeriod"], info["endPeriod"] = \
                            info["endPeriod"], info["startPeriod"]
                    info["_explicitPeriod"] = bool(
                        RE_PERIOD_RANGE.search(" ".join(part)))
                    courses.append(info)
                    current = info

    # 丢掉两类噪声：
    #   1. 没有课名的（纯续行碎片）
    #   2. 「只占 1 节 + 周次是默认值 + 没教师 + 名字像地点」——
    #      这类其实是课表里写在下一行的教室，被 OCR 当成了课名
    #      （典型如「收本3号数子按3-310」）。
    clean = []
    for c in courses:
        if not c.get("name"):
            continue
        if (c.get("startPeriod") == c.get("endPeriod")
                and c.get("startWeek") == 1 and c.get("endWeek") == 16
                and not c.get("teacher")
                and looks_like_place(c["name"])):
            continue
        c.pop("_explicitPeriod", None)
        clean.append(c)
    courses = clean
    courses.sort(key=lambda x: (x["weekday"], x["startPeriod"]))
    return courses


def cell_has_content(texts):
    return any(t and t not in NOISE_WORDS for t in texts)


# ---------------- 主流程 ----------------
def recognize(img_path):
    # 行边界用像素横线（实测很准），列边界用表头位置（像素竖线不可靠）
    ys, xs = find_grid_lines(img_path)
    if len(ys) < 3:
        print("没检测到表格横线，无法切分")
        return [], []
    print(f"行边界 {len(ys)} 条；列边界逐行带检测")

    cells = ocr_cells(img_path, ys, xs)
    periods = parse_times(cells, len(xs) - 1)
    print(f"作息时间解析出 {len(periods)} 节")

    courses = build_courses(cells, periods)
    clean = [{k: v for k, v in p.items() if k != "_row"} for p in periods]
    return courses, clean


def to_app_payload(courses, periods):
    """转成 App 备份格式 —— 这样 App 用现成的「导入备份」就能直接吃下。

    App 的备份结构（见 lib/services/storage.dart 的 exportJson）：
        {
          "version": 1,
          "exportedAt": "...",
          "courses":  [{id, name, weekday, startPeriod, endPeriod,
                        room, teacher, startWeek, endWeek, weekType, note}, ...],
          "periods":  [{period, startMinute, endMinute}, ...],
          "alarms":   []
        }
    """
    import time

    def mk_course(c, i):
        return {
            "id": f"ocr_{int(time.time())}_{i}",
            "name": c.get("name", ""),
            "weekday": int(c.get("weekday", 1)),
            "startPeriod": int(c.get("startPeriod", 1)),
            "endPeriod": int(c.get("endPeriod", 1)),
            "room": c.get("room", ""),
            "teacher": c.get("teacher", ""),
            "startWeek": int(c.get("startWeek", 1)),
            "endWeek": int(c.get("endWeek", 16)),
            "weekType": c.get("weekType", "all"),
            "note": c.get("note", ""),
        }

    return {
        "version": 1,
        "exportedAt": "",
        "courses": [mk_course(c, i) for i, c in enumerate(courses)],
        "periods": [
            {"period": int(p["period"]),
             "startMinute": int(p["start"]),
             "endMinute": int(p["end"])}
            for p in periods
        ],
        "alarms": [],
    }


def run_debug(img):
    """诊断模式：把「检测到了什么」全部打印出来。

    为什么需要：
        换一个学校的课表时，识别结果往往不对，但用户不知道卡在哪一步 ——
        是没找到网格线？还是切出来的格子不对？还是字段解析错了？
        这个模式按流水线顺序把中间结果全打印出来，不用读源码也能定位。

    对应关系：
        步骤 1 失败  -> 调 H_TOL / V_TOL，或图片太糊
        步骤 2 失败  -> 图片不是「表格型」课表（可能是列表式，需要另写解析）
        步骤 3 基本对 -> 改 PLACE_WORDS / 正则
    """
    from PIL import Image as _Image
    im = _Image.open(img)
    print("=" * 74)
    print("诊断模式")
    print("=" * 74)
    print(f"图片：{img}")
    print(f"尺寸：{im.width} x {im.height}")
    print()

    # ---- 步骤 1：网格线 ----
    print("-" * 74)
    print("步骤 1 / 检测网格线")
    print("-" * 74)
    ys, xs = find_grid_lines(img)
    print(f"横线 {len(ys)} 条：{ys}")
    if len(ys) >= 2:
        gaps = [ys[i + 1] - ys[i] for i in range(len(ys) - 1)]
        print(f"  行高：{gaps}")
    print(f"竖线 {len(xs)} 条：{xs}")
    if len(xs) >= 2:
        gaps = [xs[i + 1] - xs[i] for i in range(len(xs) - 1)]
        print(f"  列宽：{gaps}")
        print("  提示：列宽突然变成一半，说明这张表的下午部分用了压缩列，")
        print("        这是常见的导出怪癖，属正常现象。")
    if len(ys) < 3 or len(xs) < 3:
        print()
        print("  !! 网格线太少，切不出表格。")
        print("     处理办法：")
        print("       - 确认图片是「表格型」课表（有横竖线），不是列表式")
        print("       - 调低文件顶部的 H_TOL / V_TOL（例如 0.45 / 0.40）")
        print("       - 换更清晰的图片（放大后重试）")
        return
    print()

    # ---- 步骤 2：逐格 OCR ----
    print("-" * 74)
    print("步骤 2 / 逐格识别")
    print("-" * 74)
    cells = ocr_cells(img, ys, xs)
    if not cells:
        print("  没识别出任何文字。可能是图片太模糊，或网格线把文字切坏了。")
        return
    print()

    # ---- 步骤 3：时间栏与行对应 ----
    print("-" * 74)
    print("步骤 3 / 时间栏（左侧第 0 列）")
    print("-" * 74)
    periods = parse_times(cells, len(xs) - 1)
    if not periods:
        print("  没解析出作息时间。看看下面时间栏的原始文字，对照改 RE_TIME_RANGE。")
        for (r, c), texts in sorted(cells.items()):
            if c == 0:
                print(f"    行{r}: {texts}")
        return
    print(f"  解析出 {len(periods)} 节")
    for p in periods:
        s, e = p["start"], p["end"]
        print(f"    第{p['period']:2d}节  {s // 60:02d}:{s % 60:02d}"
              f"-{e // 60:02d}:{e % 60:02d}   (行 {p['_row']})")
    print()

    # ---- 步骤 4：每个格子的原始文字 ----
    print("-" * 74)
    print("步骤 4 / 有内容的格子（原始文字）")
    print("-" * 74)
    wd = {1: "周一", 2: "周二", 3: "周三", 4: "周四",
          5: "周五", 6: "周六", 7: "周日"}
    for (r, c), texts in sorted(cells.items()):
        if c == 0:
            continue
        tag = wd.get(c, f"第{c}列")
        print(f"  [行{r} {tag}] {texts}")
        parts = split_paired_cell(texts)
        if len(parts) > 1:
            print(f"      （检测到本格装了两门课，已按奇偶位拆成 {len(parts)} 份）")
            for i, (part, off) in enumerate(parts):
                print(f"        第{i + 1}份 → 星期偏移 +{off}: {part}")
    print()

    # ---- 步骤 5：最终结果 ----
    print("-" * 74)
    print("步骤 5 / 解析结果")
    print("-" * 74)
    courses = build_courses(cells, periods)
    print(f"  共 {len(courses)} 门")
    for c in courses:
        print(f"    {wd.get(c['weekday'], '?')} 第{c['startPeriod']}-{c['endPeriod']}节"
              f" 第{c['startWeek']}-{c['endWeek']}周  {c['name']}")
        print(f"        教师={c['teacher'] or '—'}  地点={c['room'] or '—'}")
    print()
    print("=" * 74)
    print("怎么看这份诊断：")
    print("  · 步骤 1 的列宽/行高是否合理？不合理 -> 调 H_TOL / V_TOL")
    print("  · 步骤 3 的时间栏是否全对？不对 -> 改 RE_TIME_RANGE")
    print("  · 步骤 4 的每格文字是否完整？缺字段 -> 改格内解析顺序")
    print("  · 步骤 5 的课程名/地点是否错位？-> 改 PLACE_WORDS / 正则")
    print("=" * 74)


def main():
    args = [a for a in sys.argv[1:]]

    debug = False
    if "--debug" in args:
        debug = True
        args.remove("--debug")
    if "-h" in args or "--help" in args or not args:
        print(__doc__)
        print()
        print("用法：")
        print("    python recognize_schedule.py 课表图片.png")
        print("    python recognize_schedule.py 课表图片.png --debug")
        print()
        print("  --debug   打印中间结果（网格线、每格原始文字、解析步骤），")
        print("            换别的学校课表时用它定位问题。")
        sys.exit(0 if ("-h" in sys.argv[1:] or "--help" in sys.argv[1:]) else 1)

    img = args[0]
    if not os.path.exists(img):
        print(f"找不到文件：{img}")
        sys.exit(1)

    if debug:
        run_debug(img)
        return

    print(f"识别中：{img}\n")
    courses, periods = recognize(img)

    wd = {1: "周一", 2: "周二", 3: "周三", 4: "周四",
          5: "周五", 6: "周六", 7: "周日"}

    print()
    print("=" * 74)
    print(f"作息时间（{len(periods)} 节）")
    print("=" * 74)
    for p in periods:
        s = f"{p['start'] // 60:02d}:{p['start'] % 60:02d}"
        e = f"{p['end'] // 60:02d}:{p['end'] % 60:02d}"
        print(f"  第{p['period']:2d}节  {s}-{e}")

    print()
    print("=" * 74)
    print(f"课程（{len(courses)} 门）")
    print("=" * 74)
    for c in courses:
        print(f"  {wd.get(c['weekday'], '?')} 第{c['startPeriod']:>2}-{c['endPeriod']:<2}节  "
              f"第{c['startWeek']:>2}-{c['endWeek']:<2}周  {c['name']}")
        print(f"          教师={c['teacher'] or '—'}  地点={c['room'] or '—'}")

    # 输出 App 可直接导入的备份文件
    payload = to_app_payload(courses, periods)
    outdir = os.path.dirname(os.path.abspath(img))
    out = os.path.join(outdir, "课表导入.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)

    print()
    print("=" * 74)
    print(f"已生成可供 App 直接导入的文件：\n  {out}")
    print("在 App 的「设置 -> 导入课表文件」里选择它即可。")


if __name__ == "__main__":
    main()
