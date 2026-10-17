import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/models/image_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/screens/player_screen.dart';

/// 复现：播放中“返回上一张”后图片显示“加载失败”。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<ImageItem> images;
  late List<Object> streamErrors;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // 测试环境没有原生实现：拦截 wakelock_plus 的 pigeon BasicMessageChannel。
    // 注意 pigeon 使用自定义 _PigeonCodec，因此这里用原始字节回复，不解析入参。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reply = const StandardMessageCodec().encodeMessage(<Object?>[null]);
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface'
        '.WakelockPlusApi.$name',
        (message) async => reply,
      );
    }

    tempDir = Directory.systemTemp.createTempSync('ff_repro');
    images = [];
    for (var i = 0; i < 3; i++) {
      final file = File('${tempDir.path}${Platform.pathSeparator}img$i.png');
      file.writeAsBytesSync(img.encodePng(img.Image(width: 400, height: 300)));
      images.add(ImageItem(name: 'img$i.png', path: file.path));
    }

    // 直接在同一个 ImageStream 上挂一个 onError 监听，用于抓取被广播的错误。
    streamErrors = [];
    for (final item in images) {
      final stream = FileImage(
        File(item.path),
      ).resolve(ImageConfiguration.empty);
      stream.addListener(
        ImageStreamListener(
          (info, synchronousCall) => info.dispose(),
          onError: (error, stackTrace) => streamErrors.add(error),
        ),
      );
    }
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 让真实的文件读取/解码有机会完成，然后再渲染一帧。
  Future<void> settleRealAsync(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<SlideProvider> pumpPlayer(
    WidgetTester tester, {
    required int startIndex,
  }) async {
    final slide = SlideProvider();
    final settings = SettingsProvider();
    // 避免测试环境走 Windows FFI 全屏逻辑
    settings.setStartFullscreen(false);
    settings.setAutoPlay(true);
    settings.setPresetInterval(60000);
    slide.setImages(images);
    slide.goToImage(startIndex);
    slide.startPlay();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SlideProvider>.value(value: slide),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await settleRealAsync(tester);
    return slide;
  }

  /// 与真实交互一致：走全局键盘监听。
  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settleRealAsync(tester);
  }

  testWidgets('返回上一张（目标是刚看过的、已缓存的图片）', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    final l10n = AppLocalizations.of(tester.element(find.byType(PlayerScreen)));
    expect(find.text(l10n.imageLoadFailed), findsNothing, reason: '初始就失败');
    expect(slide.currentIndex, 0);

    // 先向前一张（把 img1 正常显示出来），再退回 img0。
    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(slide.currentIndex, 1);
    await pressKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(slide.currentIndex, 0);

    expect(
      find.text(l10n.imageLoadFailed),
      findsNothing,
      reason: '返回上一张后失败；捕获到的流错误：$streamErrors',
    );
    // 图片流本身不应报出任何错误（回归点：build 期间 setState 会被广播为加载失败）
    expect(streamErrors, isEmpty, reason: '图片流报错：$streamErrors');
  });

  testWidgets('第一张往回翻（跨首尾到最后一张）', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    final l10n = AppLocalizations.of(tester.element(find.byType(PlayerScreen)));

    await pressKey(tester, LogicalKeyboardKey.arrowLeft);
    expect(slide.currentIndex, 2);

    expect(
      find.text(l10n.imageLoadFailed),
      findsNothing,
      reason: '跨首尾往回翻后失败；捕获到的流错误：$streamErrors',
    );
  });

  testWidgets('放大后按播放（等同于点击播放按钮）：复位缩放并直接切下一张', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);
    expect(slide.currentIndex, 0);

    // ↑ 放大；放大后自动播放暂停（工具栏显示为播放图标 ▶）
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(
      find.byIcon(Icons.play_circle),
      findsOneWidget,
      reason: '放大状态下工具栏应显示“暂停状态”的播放图标',
    );

    // 等同于点击工具栏播放按钮：视为“这张已看完”，应立即切下一张
    await pressKey(tester, LogicalKeyboardKey.space);
    expect(slide.currentIndex, 1, reason: '放大时点击播放应直接切到下一张');
    expect(
      find.byIcon(Icons.pause_circle),
      findsOneWidget,
      reason: '切图后应恢复自动播放，工具栏显示暂停图标',
    );
  });

  testWidgets('放大后拖到边缘：拖拽过程中不切图，松开左键才切换', (tester) async {
    final slide = await pumpPlayer(tester, startIndex: 0);

    // ↑ 放大。400x300 的图片放大后横向仍不足一屏（横向可平移量为 0，
    // 即一开始就“顶在边缘”），向左拖出属于“顶住左边缘继续往外推”。
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(slide.currentIndex, 0);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(slide.currentIndex, 0, reason: '拖拽过程中不应立即切图');

    // 松开左键时才判断：仍顶在边缘 → 切下一张
    await gesture.up();
    await tester.pump();
    expect(slide.currentIndex, 1, reason: '松开左键后应切到下一张');
  });
}
