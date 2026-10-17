import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/screens/home_screen.dart';
import 'package:steam_flow/screens/help_screen.dart';
import 'package:steam_flow/screens/player_screen.dart';
import 'package:steam_flow/screens/settings_screen.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 瀑布流会同时预解码「当前批 + 下一批」（各 30 张）。
  // 按卡片真实尺寸解码后单张约 2~3MB，60 张已接近默认的 100MiB 上限，
  // 一旦被驱逐，滚回去时又要重新解码，表现为来回滚动卡顿。
  // 这里放宽到 256MiB（图片像素本身仍按真实卡片尺寸解码，不会失控）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;

  final settingsProvider = SettingsProvider();
  await settingsProvider.loadSettings();

  final slideProvider = SlideProvider();
  if (settingsProvider.lastFolderPaths.isNotEmpty) {
    slideProvider.setFolderPaths(settingsProvider.lastFolderPaths);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: slideProvider),
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
