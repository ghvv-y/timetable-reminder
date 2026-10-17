// 构建标识卡片：显示 APK 版本号与构建时间
//
// 用途：覆盖安装后一眼确认装的是不是最新那版。
// 之前所有包都是 0.1.0，分不清新旧，导致「功能明明做了却没生效」的误判。

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class BuildStampCard extends StatefulWidget {
  const BuildStampCard({super.key});

  @override
  State<BuildStampCard> createState() => _BuildStampCardState();
}

class _BuildStampCardState extends State<BuildStampCard> {
  String _version = '读取中…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _version = '未知（电脑端无此信息）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFFF6F7FB),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.info_outline, size: 16, color: Color(0xFF888888)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '构建版本：$_version',
                style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
