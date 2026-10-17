# R8 / ProGuard 规则
#
# 背景：google_mlkit_text_recognition 的公共接口里引用了多个语种识别器
# （中文、日文、韩文、梵文等），但应用只依赖其中一部分。
# release 版开启代码压缩后，R8 会因为找不到未引入语种的类而报
# 「Missing classes detected while running R8」并中断构建。
#
# 应用实际只使用中文识别（课表为中文），因此：
# 1. 引入 google_mlkit_chinese_text_recognition 提供中文模型；
# 2. 对其余语种用 -dontwarn 忽略，它们不会在运行时被加载。

# ML Kit 基础与中文识别
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# 未引入的其它语种识别器（不会被运行时调用）
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Flutter 嵌入层
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# 闹钟与短信接收器、文件选择通道（由系统按名字调用，必须保留）
-keep class com.example.timetable_app.** { *; }
