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
import 'package:steam_flow/services/remote_copy_service.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 全局路由观察者：子页面返回时刷新统计、排除分组与共享状态
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
      initialRoute: '/',
      navigatorObservers: [appRouteObserver],
      routes: {
        '/': (context) => const HomeScreen(),
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
