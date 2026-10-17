// 应用入口：极简三页界面（课程表 / 闹钟 / 识别 / 设置）
//
// 设计原则：界面简洁、层级少、无广告、无多余动画。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/alarm_page.dart';
import 'pages/ocr_page.dart';
import 'pages/schedule_page.dart';
import 'pages/settings_page.dart';
import 'services/app_state.dart';
import 'services/permissions.dart';
import 'services/screen_capture.dart';

const String kAppName = '课表提醒';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 注册屏幕截取回调（悬浮球截完图要回传给识别流程）
  ScreenCapture.init();
  runApp(const TimetableApp());
}

class TimetableApp extends StatelessWidget {
  const TimetableApp({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState();

    return ChangeNotifierProvider<AppState>(
      create: (_) => state..init(),
      child: MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6BFF)),
          scaffoldBackgroundColor: const Color(0xFFF6F7FB),
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            elevation: 0,
            backgroundColor: Colors.transparent,
            foregroundColor: Color(0xFF1A1A1A),
          ),
        ),
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  /// 本次启动是否已经做过权限检查
  bool _checked = false;

  static const List<Widget> _pages = <Widget>[
    SchedulePage(),
    AlarmPage(),
    OcrPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台时重算周次。
    // 场景：周日晚上打开过、周一早上再打开（或 App 一直没退出），
    // 此时应该自动跳到新的一周，而不是等用户手动点。
    if (state == AppLifecycleState.resumed) {
      context.read<AppState>().refreshWeekIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();

    if (!state.loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // 首次启动：自动检查权限，缺哪项就在对话框里列出来
    if (!_checked && !state.startupCheckDone) {
      _checked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkPermissions());
    }

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _index, children: _pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (int i) => setState(() => _index = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '课程表',
          ),
          NavigationDestination(
            icon: Icon(Icons.alarm_outlined),
            selectedIcon: Icon(Icons.alarm),
            label: '闹钟',
          ),
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: '识别',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  /// 首次启动的权限检查：只提示、不阻塞，用户也可以先跳过
  Future<void> _checkPermissions() async {
    if (!mounted) return;
    final AppState state = context.read<AppState>();
    state.markStartupCheckDone();

    final List<PermissionCheckItem> items = await state.permissionChecks();
    final List<PermissionCheckItem> missing =
        items.where((PermissionCheckItem i) => !i.ok && i.critical).toList();

    if (missing.isEmpty || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('还有几项需要设置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('为了到点能发出短信并同步到手表，建议先补齐下面几项：',
                    style: TextStyle(fontSize: 13, height: 1.7)),
                const SizedBox(height: 10),
                for (final PermissionCheckItem item in missing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('• ${item.name}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(item.detail,
                            style: const TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: Color(0xFF666666))),
                        if (item.actionHint.isNotEmpty)
                          Text(item.actionHint,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF3A6BC8))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final String summary = await state.requestAllPermissions();
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(summary),
                    duration: const Duration(seconds: 5),
                  ),
                );
              },
              child: const Text('一键授予'),
            ),
          ],
        );
      },
    );
  }
}
