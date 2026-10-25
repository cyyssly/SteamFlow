import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/screens/folder_selection_screen.dart';
import 'package:steam_flow/screens/lan_devices_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child, SettingsProvider settings, SlideProvider slide) {
    final lan = LanProvider(settings: settings, slide: slide);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: slide),
        ChangeNotifierProvider.value(value: lan),
      ],
      child: MaterialApp(home: child),
    );
  }

  testWidgets('内网页只展示共享开关与本地文件夹开关', (tester) async {
    final settings = SettingsProvider();
    final slide = SlideProvider();
    const folder = '/tmp/steam_flow_videos';
    slide.setFolderPaths([folder]);

    await tester.pumpWidget(wrap(const LanDevicesScreen(), settings, slide));
    await tester.pump();

    final loc = AppLocalizations.of(
      tester.element(find.byType(LanDevicesScreen)),
    );
    expect(find.text(loc.lanShareTitle), findsOneWidget);
    expect(find.text(loc.localFoldersSection), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('share-$folder')), findsOneWidget);
    // 设备列表与共享源已迁出本页
    expect(find.text(loc.addShareSource), findsNothing);

    // 总开关联动全部文件夹
    await tester.tap(find.widgetWithText(SwitchListTile, loc.lanShareTitle));
    await tester.pump();
    expect(settings.lanShareEnabled, isTrue);
    expect(settings.isLocalFolderShared(folder), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, loc.lanShareTitle));
    await tester.pump();
    expect(settings.lanShareEnabled, isFalse);
    expect(settings.isLocalFolderShared(folder), isFalse);
  });

  testWidgets('选择页底部提供添加文件夹与添加共享源', (tester) async {
    final settings = SettingsProvider();
    final slide = SlideProvider();

    await tester.pumpWidget(
      wrap(const FolderSelectionScreen(), settings, slide),
    );
    await tester.pump();

    final loc = AppLocalizations.of(
      tester.element(find.byType(FolderSelectionScreen)),
    );
    expect(find.text(loc.addFolder), findsOneWidget);
    expect(find.text(loc.addShareSource), findsOneWidget);
    expect(find.text(loc.startPlay), findsOneWidget);
  });

  testWidgets('选择页会剔除磁盘上已不存在的文件夹', (tester) async {
    final settings = SettingsProvider();
    final slide = SlideProvider();
    const missing = '/tmp/steam_flow_missing_folder_for_test_9f2c';
    slide.setFolderPaths([missing]);

    await tester.pumpWidget(
      wrap(const FolderSelectionScreen(), settings, slide),
    );
    // 等待真实的目录存在性检查完成，再按固定帧数重建
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();

    expect(slide.folderPaths, isEmpty);
    expect(settings.lastFolderPaths, isEmpty);
  });
}
