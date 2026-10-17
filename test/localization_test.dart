import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/screens/settings_screen.dart';

/// 繁体中文必须带 `Hant` script，否则会被判成简体。
const zhHant = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');

void main() {
  group('AppLocalizations 语言判定', () {
    test('zh-Hans 判为简体', () {
      final l10n = AppLocalizations(const Locale('zh', 'CN'));

      expect(l10n.isZhCN, isTrue);
      expect(l10n.isZhTW, isFalse);
      expect(l10n.settingsTitle, '设置');
    });

    test('zh-Hant 判为繁体（回归：scriptCode 必须为 Hant）', () {
      final l10n = AppLocalizations(zhHant);

      expect(l10n.isZhTW, isTrue);
      expect(l10n.isZhCN, isFalse);
      expect(l10n.settingsTitle, '設置');
    });

    test('en 判为英文', () {
      final l10n = AppLocalizations(const Locale('en', 'US'));

      expect(l10n.isEn, isTrue);
      expect(l10n.settingsTitle, 'Settings');
    });
  });

  /// 以指定语言渲染设置页；视口取足够高，避免 ListView 懒加载导致分组未被构建。
  ///
  /// `supportedLocales` 必须显式给出：`WidgetsApp` 只有在其中找得到传入的
  /// `locale` 时才采用它，否则会回落到平台语言。
  ///
  /// Global 系列 delegate 也必须给出：`MaterialApp` 总会追加
  /// `DefaultMaterialLocalizations`（仅支持 en），而 `_debugCheckLocalizations`
  /// 是按 delegate 的 `type` 判定的，缺了 Global 系列就会报 locale 不受支持。
  Future<void> pumpSettings(WidgetTester tester, Locale locale) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          locale: locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            zhHant,
            Locale('en', 'US'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('设置页在 zh-Hant 下渲染繁体文案', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, zhHant);

    expect(find.text('播放設置'), findsWidgets);
    expect(find.text('播放设置'), findsNothing);
  });

  testWidgets('设置页在 en 下渲染英文文案', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, const Locale('en', 'US'));

    expect(find.text('Playback'), findsWidgets);
  });
}
