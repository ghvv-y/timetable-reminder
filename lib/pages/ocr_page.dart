// 课表提醒 (Timetable Reminder)
// Copyright (C) 2026 课表提醒 contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本程序是自由软件：你可以依据 GNU General Public License 第 3 版
// （或你选择的更高版本）的条款重新分发和/或修改它。
// 协议全文见项目根目录的 LICENSE 文件。
//
// 识别页：从课表截图 / 拍照中识别课程，并理解边侧标注的作息时间
//
// 流程：选图 → 文字识别 → 划分课程格与时间栏 → 对齐节次与时间 → 人工确认 → 入库
//
// 识别结果会连同「原始文字」一起展示，便于判断问题出在哪一环：
//   - 原始文字为空         → 这张图没认到字（图片太模糊 / 太小 / 没有文字）
//   - 有原始文字但无课程    → 认到字了，但解析规则没匹配上（需要人工校对或调整规则）
//
// 手机端使用 ML Kit 文字识别；电脑端不支持，界面会提示改为手动录入。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../model/models.dart';
import '../model/period_time.dart';
import '../ocr/table_parser.dart';
import '../ocr/cell_parser.dart';
import '../ocr/course_dictionary.dart';
import '../ocr/paste_parser.dart';
import '../ocr/ppocr_service.dart';
import '../ocr/text_recognizer.dart';
import '../services/app_state.dart';
import '../services/screen_capture.dart';
import '../utils/time_utils.dart';

class OcrPage extends StatefulWidget {
  const OcrPage({super.key});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  bool _busy = false;

  /// 是否使用离线 PP-OCR 引擎
  ///
  /// 安卓默认开启：Kotlin 侧切格 + 逐格识别，和桌面工具同一套模型，
  /// 时间栏与中文课名的准确率远高于旧的 ML Kit 整图识别。
  /// 保留 ML Kit 作为对照/兜底（万一某个机型跑不动 ONNX）。
  bool _usePpOcr = true;

  /// 识别产物（结构化文本块 + 原始文字）
  OcrOutcome? _outcome;

  /// 解析结果
  ParseResult? _result;

  /// 出错时的具体信息
  String? _error;

  /// 悬浮球是否已开启
  bool _screenOn = false;

  /// 是否正在处理截图
  bool _capturing = false;

  /// 当前构建版本（显示在卡片上，便于确认装的是哪一版）
  String _buildVersion = '';

  /// 截屏完成后是否自动返回课表界面
  bool _autoReturn = true;

  /// 上一次识别耗时（毫秒）
  int _lastElapsedMs = 0;

  /// 是否开启小字放大增强
  bool _enhance = ocrEnhanceSmallText;

  /// 放大倍数
  int _scale = ocrUpscaleFactor;

  @override
  void initState() {
    super.initState();
    ScreenCapture.onCaptured = _onScreenCaptured;
    ScreenCapture.onError = _onScreenError;
    PackageInfo.fromPlatform().then((PackageInfo info) {
      if (mounted) {
        setState(() => _buildVersion = '${info.version}+${info.buildNumber}');
      }
    }).catchError((Object _) => null);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!ScreenCapture.isSupported) return;
      final bool running = await ScreenCapture.isRunning();
      final bool auto = await ScreenCapture.getAutoReturn();
      if (mounted) {
        setState(() {
          _screenOn = running;
          _autoReturn = auto;
        });
      }
    });
  }

  @override
  void dispose() {
    if (ScreenCapture.onCaptured == _onScreenCaptured) {
      ScreenCapture.onCaptured = null;
    }
    if (ScreenCapture.onError == _onScreenError) {
      ScreenCapture.onError = null;
    }
    super.dispose();
  }

  /// 截屏功能出错（系统拒绝后台服务、悬浮球添加失败等）
  void _onScreenError(String reason) {
    if (!mounted) return;
    setState(() => _screenOn = false);
    _toastThrottled('screen_error_$reason', ScreenCapture.describeError(reason));
  }

  /// 悬浮球截完图后的回调
  void _onScreenCaptured(String? path) {
    if (!mounted) return;
    setState(() => _capturing = false);
    if (path == null) {
      _toastThrottled('capture_failed', '截屏失败，请重试（若反复失败，关闭屏幕识别再重新开启）');
      return;
    }
    _runOnPath(path, fromScreen: true);
  }

  /// 上一次弹提示的时间，用于节流
  final Map<String, DateTime> _lastToastAt = <String, DateTime>{};

  /// 节流版提示：同一类消息在短时间内只弹一次
  ///
  /// 背景：截屏失败时系统可能连续回调多次，导致底部反复弹「截屏失败」，
  /// 既刷屏又让人以为程序坏了。
  void _toastThrottled(String key, String text,
      {Duration window = const Duration(seconds: 8)}) {
    if (!mounted) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastToastAt[key];
    if (last != null && now.difference(last) < window) return;
    _lastToastAt[key] = now;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars(); // 顺便清掉还没消失的旧提示
    messenger.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
    );
  }

  /// 从剪贴板导入课表（主路径）
  ///
  /// 教务系统网页里复制出来的是纯文本，解析准确率 100%，
  /// 没有任何 OCR 误差，是「方便 + 准确」兼顾得最好的入口。
  Future<void> _pasteImport() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String text = (data?.text ?? '').trim();
      if (text.isEmpty) {
        _toast('剪贴板是空的——先在浏览器里长按课表，全选后复制');
        return;
      }

      final PasteParseResult? parsed = parsePastedSchedule(text);
      if (parsed == null || parsed.isEmpty) {
        _toast('剪贴板里没找到课表。请确认复制的是教务系统的课表页面（含课程列表那段）');
        return;
      }

      if (!mounted) return;
      setState(() {
        _result = ParseResult(
          periodTimes: parsed.periods,
          courses: parsed.courses,
          warnings: parsed.warnings,
        );
        _outcome = null;
      });
      _toast('已解析 ${parsed.courses.length} 条课程（${parsed.format}），请核对后导入');
    } catch (e) {
      debugPrint('剪贴板解析失败: $e');
      if (mounted) {
        setState(() => _error = e.toString());
        _toast('解析失败：$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(ImageSource source) async {
    if (!isOcrSupported) {
      _toast('当前平台不支持自动识别，可先套用默认作息模板，再手动录入课程');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 不传 imageQuality，避免系统压缩损失小字清晰度
      final XFile? file = await ImagePicker().pickImage(source: source);
      if (file == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await _recognizePath(file.path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 对指定图片路径做识别（悬浮球截图走这里）
  Future<void> _runOnPath(String path, {bool fromScreen = false}) async {
    if (!isOcrSupported) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _recognizePath(path);
      if (fromScreen) {
        _toast('已识别当前屏幕内容');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 识别 + 解析的公共流程
  ///
  /// 两条引擎路径：
  ///   - PP-OCR（推荐，安卓）：Kotlin 侧切格 + 逐格识别，桌面端验证过的方式，
  ///     时间栏和中文课名都准；识别结果按行列返回，由 cell_parser 解析。
  ///   - ML Kit（旧，兼容）：整图 OCR，中文课名容易串行，保留作对照/兜底。
  Future<void> _recognizePath(String path) async {
    try {
      final Stopwatch sw = Stopwatch()..start();

      if (_usePpOcr && PpfOcrService.isSupported) {
        // 用已导入的课表当词典纠正 OCR 错字（有则用，无则跳过）
        final CourseDictionary dict =
            CourseDictionary.fromCourses(context.read<AppState>().courses);
        CellParseResult parsed;
        try {
          parsed = await PpfOcrService.recognize(path, dictionary: dict);
        } on PpfOcrException catch (e) {
          // 有框线算法失败时自动改用无框线算法重试。
          //
          // 教务系统网页版课表是彩色色块拼接、没有绘制表格线，
          // 网格检测会判成「无表格」。这类图必须走另一条路：
          // 整图 OCR + 星期表头/时间栏锚点排版。
          if (!e.message.contains('表格线')) rethrow;
          debugPrint('有框线识别失败，改用无框线算法重试：${e.message}');
          parsed = await PpfOcrService.recognizeBorderless(path, dictionary: dict);
        }
        sw.stop();
        if (!mounted) return;

        // 把格子文字拼成「原始文字」展示，格式和 ML Kit 路径一致，
        // 这样界面上的核对卡片不用改。
        final List<TextBlock> blocks = <TextBlock>[];
        final StringBuffer raw = StringBuffer();
        double y = 0;
        for (final OcrCell c in parsed.cells) {
          for (final String line in c.lines) {
            blocks.add(TextBlock(
              text: line,
              left: 0,
              top: y,
              right: 0,
              bottom: y + 1,
            ));
            raw.writeln(line);
            y += 1;
          }
        }

        setState(() {
          _outcome = OcrOutcome(blocks: blocks, rawText: raw.toString());
          _result = ParseResult(
            periodTimes: parsed.periods,
            courses: parsed.courses,
            warnings: parsed.warnings,
          );
          _lastElapsedMs = sw.elapsedMilliseconds;
        });

        if (parsed.cells.isEmpty) {
          _toast('这张图没有认出任何文字，换清晰一些、正对屏幕的截图再试');
        } else if (parsed.courses.isEmpty && parsed.periods.isEmpty) {
          _toast(parsed.warnings.isEmpty
              ? '认到了文字但没解析出课表，请展开「识别到的原始文字」查看'
              : parsed.warnings.first);
        } else {
          _toast('离线引擎识别出 ${parsed.courses.length} 门课，请核对后导入');
        }
        return;
      }

      final OcrOutcome outcome = await recognizeBlocks(XFile(path));
      sw.stop();
      final ParseResult result = TableParser.parse(outcome.blocks);

      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _result = result;
        _lastElapsedMs = sw.elapsedMilliseconds;
      });

      if (outcome.isEmpty) {
        _toast('这张图没有认出任何文字，换清晰一些、正对屏幕的截图再试');
      } else if (result.courses.isEmpty && result.periodTimes.isEmpty) {
        _toast('认到了文字但没解析出课表，请展开「识别到的原始文字」查看，或手动录入');
      }
    } catch (e, st) {
      debugPrint('识别失败: $e\n$st');
      if (mounted) {
        setState(() => _error = e.toString());
        _toast('识别失败：$e');
      }
    }
  }

  /// 开启 / 关闭悬浮球截屏
  Future<void> _toggleScreen(bool on) async {
    if (on) {
      final bool ok = await ScreenCapture.canDrawOverlay();
      if (!ok) {
        await ScreenCapture.requestOverlayPermission();
        if (mounted) {
          _toast('请先允许「显示在其他应用上层」，返回后再点一次开启');
        }
        return;
      }
      final bool started = await ScreenCapture.start();
      if (!mounted) return;
      // 再问一次服务是否真的起来了——授权通过但服务被系统拒绝时能立刻发现
      final bool reallyRunning = started && await ScreenCapture.isRunning();
      setState(() => _screenOn = reallyRunning);
      if (reallyRunning) {
        _toast('已开启。切到课表页面点悬浮球「扫」即可截屏识别');
      } else if (started) {
        _toast('已授权，但悬浮球没能出现。请检查「显示在其他应用上层」权限与后台运行限制');
      } else {
        _toast('未获得截屏授权，屏幕识别未开启');
      }
    } else {
      await ScreenCapture.stop();
      if (mounted) {
        setState(() => _screenOn = false);
        _toast('已关闭屏幕识别，通知已消失');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        const Text('识别课表',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('支持识别课程名称与地点，并理解课表边上标注的作息时间（第几节 = 几点到几点）',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF888888))),
        const SizedBox(height: 14),

        // ===== 主路径：从剪贴板导入 =====
        //
        // 为什么把这条放在最上面：
        //   教务系统网页里复制的文本是系统给的，不存在识别误差（实测 21/21 全对），
        //   而且操作比截图更快（复制粘贴 vs 截图选图等识别）。
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: const Color(0xFFEFF5FF),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Row(
                  children: <Widget>[
                    Icon(Icons.content_paste_go, size: 18, color: Color(0xFF3A6BD6)),
                    SizedBox(width: 6),
                    Text('从剪贴板导入',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2B4E8F))),
                    SizedBox(width: 6),
                    Text('推荐',
                        style: TextStyle(fontSize: 11, color: Color(0xFF6B8FD6))),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '在教务系统网页里长按课表 → 全选 → 复制，然后点下面的按钮。\n'
                  '文本没有识别误差，比截图更准也更快。',
                  style: TextStyle(
                      fontSize: 12, height: 1.6, color: Color(0xFF5A6B8C)),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : _pasteImport,
                  icon: const Icon(Icons.download_done, size: 18),
                  label: const Text('读取剪贴板并解析'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3A6BD6),
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 14),
        // 识别引擎选择（只有安卓有离线引擎）
        if (PpfOcrService.isSupported) ...<Widget>[
          Row(
            children: <Widget>[
              const Text('识别引擎：',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF666666))),
              const SizedBox(width: 6),
              ChoiceChip(
                label: const Text('离线 PP-OCR（推荐）',
                    style: TextStyle(fontSize: 12)),
                selected: _usePpOcr,
                onSelected: _busy
                    ? null
                    : (bool v) => setState(() => _usePpOcr = true),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('ML Kit（旧）',
                    style: TextStyle(fontSize: 12)),
                selected: !_usePpOcr,
                onSelected: _busy
                    ? null
                    : (bool v) => setState(() => _usePpOcr = false),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _usePpOcr
                ? '离线 PP-OCR：切格逐格识别，时间栏和中文课名更准，首次识别会慢几秒'
                : 'ML Kit：整图识别，中文课名容易串行，只在离线引擎异常时使用',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _run(ImageSource.gallery),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('选择截图'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _run(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('拍照'),
              ),
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_capturing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text('正在截取屏幕…')),
          ),

        // 悬浮球截屏：直接截当前屏幕内容，比拍屏清晰
        if (ScreenCapture.isSupported) _screenCaptureCard(),

        if (!isOcrSupported)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('电脑端暂不支持自动识别，可套用默认作息模板并手动录入课程。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF888888))),
          ),

        // 出错详情
        if (_error != null) _errorCard(state, _error!),

        // 原始文字（排错与人工校对）
        if (_outcome != null) _rawTextCard(_outcome!),

        // 识别结果确认 / 手动录入
        if (_result != null)
          _confirmSection(context, state, _result!, _outcome)
        else
          _manualSection(context, state),

        const SizedBox(height: 16),
        const Text(
          '识别核对要点：\n'
          '1. 时间栏是否正确，尤其是上午 / 下午分栏与夏令时、冬令时两套作息。\n'
          '2. 连堂课是否被正确合并为一节。\n'
          '3. 单双周与起止周是否与课表一致。',
          style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF888888)),
        ),
      ],
    );
  }

  /// 悬浮球截屏开关卡片
  Widget _screenCaptureCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('屏幕识别（悬浮球截屏）',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                Switch(value: _screenOn, onChanged: _toggleScreen),
              ],
            ),
            Text(
              '当前版本：${_buildVersion.isEmpty ? '读取中…' : _buildVersion}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 4),
            const Text(
              '开启后，切到任意课表页面（微信、教务系统、网页都行），'
              '点悬浮球「扫」即截取当前屏幕并自动识别。',
              style: TextStyle(fontSize: 12.5, height: 1.7, color: Color(0xFF666666)),
            ),
            const SizedBox(height: 8),

            // 悬浮球颜色说明：让用户知道怎么判断截屏成功没成功
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFD6E0FF)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('悬浮球颜色就是状态：',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  _ballLegend(const Color(0xFFFFFFFF), '白色「扫」', '待机，可以点'),
                  _ballLegend(const Color(0xFFD9534F), '红色「…」', '正在截屏'),
                  _ballLegend(const Color(0xFF3BA55D), '绿色「✓」', '截屏完成'),
                  _ballLegend(const Color(0xFFE8A33D), '橙色「!」', '截屏失败'),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // 截屏完成后自动返回本应用
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('截屏后自动返回课表界面',
                  style: TextStyle(fontSize: 13.5)),
              subtitle: const Text('截完屏自动切回本应用，不用自己去最近任务里找',
                  style: TextStyle(fontSize: 11.5)),
              value: _autoReturn,
              onChanged: (bool v) async {
                setState(() => _autoReturn = v);
                await ScreenCapture.setAutoReturn(v);
              },
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFE2A8)),
              ),
              child: const Text(
                '说明：系统规定截屏必须显示常驻通知与录制图标，'
                '所以本功能只建议临时开启，用完请关闭开关——'
                '关闭后通知立即消失，闹钟提醒依旧完全静默。',
                style: TextStyle(fontSize: 12, height: 1.7),
              ),
            ),
            const SizedBox(height: 6),

            // 小字识别增强：字特别小的截图可以打开试试
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('小字放大增强',
                  style: TextStyle(fontSize: 13.5)),
              subtitle: Text(
                _enhance
                    ? '已开启：识别前先把截图放大 $_scale 倍并提高对比度。'
                        '字挤在一起、认不全时可以开；图本来就清楚的话，'
                        '开着可能反而变差，可以对比试试'
                        '${_lastElapsedMs > 0 ? '（上次识别耗时 ${_lastElapsedMs}ms）' : ''}'
                    : '默认关闭。只有当课表格子里的字特别小、识别出来缺字漏字时，'
                        '才需要打开它',
                style: const TextStyle(fontSize: 11.5),
              ),
              value: _enhance,
              onChanged: (bool v) {
                setState(() {
                  _enhance = v;
                  ocrEnhanceSmallText = v;
                });
              },
            ),
            if (_enhance)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Text('放大倍数', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 10),
                        DropdownButton<int>(
                          value: _scale,
                          underline: const SizedBox.shrink(),
                          items: <DropdownMenuItem<int>>[
                            for (final int n in <int>[1, 2, 3, 4])
                              DropdownMenuItem<int>(
                                  value: n,
                                  child:
                                      Text(n == 1 ? '1 倍（只增强）' : '$n 倍')),
                          ],
                          onChanged: (int? v) {
                            if (v == null) return;
                            setState(() {
                              _scale = v;
                              ocrUpscaleFactor = v;
                            });
                          },
                        ),
                        const Spacer(),
                        const Text('倍数越大越慢',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFF999999))),
                      ],
                    ),
                    const Text(
                      '怎么用：先按现在的设置识别一次，把结果记下来；'
                      '再打开这个开关、换个倍数识别一次，对比哪次认出来的字更全。'
                      '挑效果好的那个留着就行。',
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: Color(0xFF888888)),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: _showDiagnostics,
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('查看启动日志'),
                ),
                const Text('（悬浮球不出现时，把日志发我）',
                    style: TextStyle(fontSize: 11, color: Color(0xFF999999))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮球颜色图例
  Widget _ballLegend(Color dot, String name, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              border: Border.all(
                  color: const Color(0xFFB9C4D6), width: 1.2),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text(name,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(desc,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF666666))),
          ),
        ],
      ),
    );
  }

  /// 展示原生侧诊断日志
  Future<void> _showDiagnostics() async {
    final String log = await ScreenCapture.readDiagnostics();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('截屏功能启动日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: const TextStyle(fontSize: 11.5, height: 1.6),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await ScreenCapture.clearDiagnostics();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 出错详情：把真实的异常信息展示出来，并提示常见原因
  Widget _errorCard(AppState state, String error) {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFF3F3),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('识别过程出错',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(error,
                style: const TextStyle(fontSize: 12, height: 1.6)),
            const SizedBox(height: 8),
            const Text(
              '常见原因：\n'
              '· 没给「照片和视频」权限 —— 到系统设置里给本应用放开\n'
              '· 图片格式特殊或文件已损坏\n'
              '· 系统把 App 的后台权限收得太紧\n'
              '可以先点下面的「套用默认模板」+「手动录入课程」，课表照常能用。',
              style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF666666)),
            ),
          ],
        ),
      ),
    );
  }

  /// 原始文字卡片：判断「有没有认出字」的关键依据
  Widget _rawTextCard(OcrOutcome outcome) {
    final String raw = outcome.rawText.trim();
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: const Text('识别到的原始文字',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          raw.isEmpty
              ? '一个文字都没认到（说明图片本身没被识别出文字）'
              : '共 ${outcome.lineCount} 行 / ${raw.length} 字符（点开可对照）',
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF888888)),
        ),
        initiallyExpanded: raw.isEmpty,
        children: <Widget>[
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F7FB),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              raw.isEmpty ? '（无）' : raw,
              style: const TextStyle(fontSize: 12, height: 1.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _manualSection(BuildContext context, AppState state) {
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('手动补充',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('识别不理想时，可先套用默认作息模板，再逐条改成你们学校的时间，课程也可以手动添加。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF888888))),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: () async {
                    await state.setPeriodTimes(defaultPeriodTimes());
                    await state.regenerateCourseAlarms();
                    _toast('已套用默认作息模板');
                  },
                  child: const Text('套用默认模板'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () {
                    final AppState s = context.read<AppState>();
                    _showQuickAdd(context, s);
                  },
                  child: const Text('手动添加课程'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showQuickAdd(BuildContext context, AppState state) {
    final TextEditingController nameCtl = TextEditingController();
    final TextEditingController roomCtl = TextEditingController();
    int weekday = 1;
    int start = 1;
    int end = 2;

    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setLocal) {
            return AlertDialog(
              title: const Text('手动添加课程'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameCtl,
                      decoration: const InputDecoration(labelText: '课程名'),
                    ),
                    TextField(
                      controller: roomCtl,
                      decoration: const InputDecoration(labelText: '地点'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const Text('星期　'),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: weekday,
                            items: List<DropdownMenuItem<int>>.generate(
                              7,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text(weekdayName(i + 1)),
                              ),
                            ),
                            onChanged: (int? v) =>
                                setLocal(() => weekday = v ?? weekday),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const Text('节次　'),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: start,
                            items: List<DropdownMenuItem<int>>.generate(
                              14,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text('第${i + 1}节'),
                              ),
                            ),
                            onChanged: (int? v) => setLocal(() {
                              start = v ?? start;
                              if (end < start) end = start;
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: end,
                            items: List<DropdownMenuItem<int>>.generate(
                              14,
                              (int i) => DropdownMenuItem<int>(
                                value: i + 1,
                                child: Text('到第${i + 1}节'),
                              ),
                            ),
                            onChanged: (int? v) =>
                                setLocal(() => end = v ?? end),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (nameCtl.text.trim().isEmpty) return;
                    final Course c = Course(
                      id: 'manual_${DateTime.now().microsecondsSinceEpoch}',
                      name: nameCtl.text.trim(),
                      weekday: weekday,
                      startPeriod: start,
                      endPeriod: end,
                      room: roomCtl.text.trim(),
                    );
                    Navigator.pop(ctx);
                    await state.upsertCourse(c);
                    await state.regenerateCourseAlarms();
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _confirmSection(
      BuildContext context, AppState state, ParseResult r, OcrOutcome? outcome) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (r.warnings.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7E6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFE2A8)),
            ),
            child: Text(
              r.warnings.join('\n'),
              style: const TextStyle(fontSize: 12, height: 1.7),
            ),
          ),
        Card(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('解析出 ${r.periodTimes.length} 个节次时间、${r.courses.length} 门课程',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                for (final PeriodTime pt in r.periodTimes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 70,
                          child: Text('第${pt.period}节',
                              style: const TextStyle(fontSize: 13)),
                        ),
                        Text(
                          '${fmtMinute(pt.startMinute)} - ${fmtMinute(pt.endMinute)}',
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF444444)),
                        ),
                        const Spacer(),
                        Text(
                          '提醒 ${fmtMinute(pt.startMinute - state.settings.preClassMinutes)}'
                          ' / ${fmtMinute(pt.endMinute - state.settings.postClassMinutes)}',
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFF8896B8)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 10),
                if (r.courses.isEmpty)
                  const Text('没有解析出课程，可在下面手动添加，或展开上面的原始文字对照。',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF888888))),
                for (final Course c in r.courses)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${weekdayName(c.weekday)} 第${c.startPeriod}-${c.endPeriod}节　${c.name}'
                      '${c.room.isEmpty ? '' : '　${c.room}'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 12),
                // 两种导入方式：
                //   覆盖 = 用识别结果替换整张课表（换学期、重新识别时用）
                //   合并 = 只把新课程追加进去（补录、分批导入时用，不丢已有课程）
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton(
                        onPressed: r.courses.isEmpty &&
                                r.periodTimes.isEmpty
                            ? null
                            : () async {
                                await state.importParsed(r);
                                await state.regenerateCourseAlarms();
                                if (context.mounted) {
                                  _toast(
                                      '已导入 ${r.courses.length} 门课程，并生成上下课提醒');
                                }
                              },
                        child: const Text('覆盖导入'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: r.courses.isEmpty &&
                                r.periodTimes.isEmpty
                            ? null
                            : () async {
                                final int before = state.courses.length;
                                await state
                                    .importParsed(r, replace: false);
                                await state.regenerateCourseAlarms();
                                if (context.mounted) {
                                  final int added =
                                      state.courses.length - before;
                                  _toast(added > 0
                                      ? '已合并 $added 门课程（原有 $before 门保留）'
                                      : '没有新增课程（这些课已经在课表里了）');
                                }
                              },
                        child: const Text('合并导入'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '覆盖导入会替换整张课表；合并导入只追加新课程，适合分批补录。',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: () => setState(() {
                        _result = null;
                        _outcome = null;
                        _error = null;
                      }),
                      child: const Text('清除结果'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 4)),
    );
  }
}
