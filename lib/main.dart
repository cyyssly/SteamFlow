import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/screens/home_screen.dart';
import 'package:steam_flow/screens/help_screen.dart';
import 'package:steam_flow/screens/player_screen.dart';
import 'package:steam_flow/screens/settings_screen.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/desktop_tray_service.dart';
import 'package:steam_flow/services/playback_progress_service.dart';
import 'package:steam_flow/services/remote_copy_service.dart';
import 'package:steam_flow/services/single_instance_service.dart';
import 'package:steam_flow/services/video_formats.dart';
import 'package:steam_flow/services/windows_context_menu_service.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 全局路由观察者：子页面返回时刷新统计、排除分组与共享状态
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 全局导航键：供单实例路径转发在任意页面直接跳转到播放页
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尽早注册单实例通道，防止第二个实例转发来的路径在启动期间丢失
  SingleInstanceService.instance.initializeChannel();

  // 初始化 media_kit：播放页的 Player/Video 依赖它完成原生侧准备，
  // 必须在任何 Player 实例创建之前调用。
  MediaKit.ensureInitialized();

  // 瀑布流会同时预解码「当前批 + 下一批」（各 30 个）。
  // 按卡片真实尺寸解码后单个约 2~3MB，60 个已接近默认的 100MiB 上限，
  // 一旦被驱逐，滚回去时又要重新解码，表现为来回滚动卡顿。
  // 这里放宽到 256MiB（视频像素本身仍按真实卡片尺寸解码，不会失控）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;

  final settingsProvider = SettingsProvider();
  await settingsProvider.loadSettings();

  // 读取已保存的视频进度（「接续播放」使用），播放页查询时走内存
  await PlaybackProgressService.instance.load();

  // 右键菜单命令记录的是注册时的 exe 绝对路径，便携版被移动过目录后
  // 旧路径就会失效。启动时：
  // · 开关为开 → 按当前 exe 路径重新注册一次；
  // · 开关为关但注册表项仍存在（例如由其他副本注册过）→ 重新注册，
  //   并把开关自动打开，保证换位置后菜单依然可用。
  if (Platform.isWindows) {
    // 注册表里只能存静态文本，按当前语言写入菜单标题与文件类型说明
    final loc = AppLocalizations.fromIndex(settingsProvider.languageIndex);
    if (settingsProvider.addToContextMenu) {
      unawaited(
        WindowsContextMenuService.instance.install(
          menuText: loc.contextMenuOpenWith,
        ),
      );
    } else if (await WindowsContextMenuService.instance.isInstalled()) {
      await WindowsContextMenuService.instance.install(
        menuText: loc.contextMenuOpenWith,
      );
      settingsProvider.setAddToContextMenu(true);
    }
    // 已注册过“候选默认播放器”时，保持命令路径与当前 exe 一致
    if (await WindowsContextMenuService.instance.hasDefaultAppRegistration()) {
      unawaited(
        WindowsContextMenuService.instance.installDefaultAppRegistration(
          typeName: loc.videoFileTypeName,
          description: loc.videoPlayerDescription,
        ),
      );
    }
  }

  // 右键菜单「用 SteamFlow 播放」会以视频路径作为命令行参数启动
  final initialVideoPath = _findOpenVideoArgument(args);

  // 桌面端：窗口关闭按钮的行为（退出或收起到系统托盘继续共享）
  final trayService = DesktopTrayService(settingsProvider);
  await trayService.initialize();

  final slideProvider = SlideProvider();
  if (settingsProvider.lastFolderPaths.isNotEmpty) {
    slideProvider.setFolderPaths(settingsProvider.lastFolderPaths);
  }

  // 局域网共享：启动 UDP 发现，并按设置决定是否开启本机共享服务
  final lanProvider = LanProvider(
    settings: settingsProvider,
    slide: slideProvider,
  );
  await lanProvider.initialize();

  // 清理过期且未完成的复制分片，不阻塞启动
  unawaited(RemoteCopyService.cleanupStaleParts());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: slideProvider),
        ChangeNotifierProvider.value(value: lanProvider),
      ],
      child: MyApp(initialVideoPath: initialVideoPath),
    ),
  );

  // 导航树就绪后绑定单实例服务，并补取启动早期收到的转发路径
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      SingleInstanceService.instance.attach(
        navigatorKey: appNavigatorKey,
        slideProvider: slideProvider,
      ),
    );
  });
}

/// 从命令行参数中找出需要直接打开的视频文件。
///
/// 右键菜单「用 SteamFlow 播放」会把文件路径作为唯一参数传入。
/// 同时过滤调试参数（以 `-` 开头）与不存在的文件，避免误判。
String? _findOpenVideoArgument(List<String> args) {
  for (final arg in args) {
    final path = arg.trim();
    if (path.isEmpty || path.startsWith('-')) continue;
    if (!isSupportedVideoPath(path)) continue;
    if (!File(path).existsSync()) continue;
    return path;
  }
  return null;
}

class MyApp extends StatelessWidget {
  /// 由右键菜单/命令行传入、启动后直接播放的视频路径
  final String? initialVideoPath;

  const MyApp({super.key, this.initialVideoPath});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final locale = settings.languageIndex == 0
        ? _resolveSystemLocale()
        : AppLanguage.values[settings.languageIndex].locale;

    return MaterialApp(
      title: 'SteamFlow',
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        Locale('en', 'US'),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
        fontFamily: 'NotoSansSC',
      ),
      navigatorKey: appNavigatorKey,
      initialRoute: '/',
      navigatorObservers: [appRouteObserver],
      routes: {
        '/': (context) => HomeScreen(initialVideoPath: initialVideoPath),
        '/player': (context) => const PlayerScreen(),
        '/settings': (context) => const SettingsScreen(),
        '/help': (context) => const HelpScreen(),
      },
    );
  }

  Locale _resolveSystemLocale() {
    final loc = Platform.localeName;
    if (loc.startsWith('zh')) {
      if (loc.contains('TW') || loc.contains('HK') || loc.contains('MO')) {
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      }
      return const Locale('zh', 'CN');
    }
    return const Locale('en', 'US');
  }
}
