// 文字识别入口：按平台切换实现
// - 移动端（Android / iOS）：使用 ML Kit 进行文字识别
// - 桌面端（Windows / macOS / Linux）：不支持识别，返回空结果

export 'text_recognizer_desktop.dart'
    if (dart.library.io) 'text_recognizer_io.dart';
