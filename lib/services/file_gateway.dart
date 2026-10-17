// 文件选择：通过原生通道打开系统文件选择器读取备份文件
//
// 之所以自己实现而不引入社区插件：
// file_picker 等插件把 compileSdk 写死为 34，与 Flutter 3.47 所需的 36 冲突，
// 会直接导致打包含 checkDebugAarMetadata 失败。这里只用到「选一个文件」这一件事，
// 自己实现反而更小更稳。
//
// Android：使用 Activity Result API 打开文件选择器并读取内容。
// 其它平台：返回 not_supported。

import 'package:flutter/services.dart';

class FileGateway {
  static const MethodChannel _channel =
      MethodChannel('timetable_app/file');

  /// 打开系统文件选择器并读取所选文件内容
  ///
  /// 返回 null 表示用户取消或平台不支持。
  static Future<String?> pickTextFile() async {
    try {
      return await _channel.invokeMethod<String>('pickTextFile');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
