import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/video_scan_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('扫描时过滤已排除视频（Windows 路径大小写不敏感）', () async {
    final temp = await Directory.systemTemp.createTemp('steam_flow_scan_');
    addTearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });
    final keep = File('${temp.path}${Platform.pathSeparator}b.mp4');
    final excluded = File('${temp.path}${Platform.pathSeparator}a.mp4');
    await keep.writeAsBytes([1, 2, 3]);
    await excluded.writeAsBytes([4, 5, 6]);

    // Windows 下用大写路径验证大小写不敏感；其他平台用原始路径
    final excludedValue = Platform.isWindows
        ? excluded.path.toUpperCase()
        : excluded.path;
    SharedPreferences.setMockInitialValues({
      'excludedPaths': json.encode([excludedValue]),
    });
    final settings = SettingsProvider();
    await settings.loadSettings();

    final videos = await VideoScanService.scanFolder(temp.path, settings);
    expect(videos.map((e) => e.path), isNot(contains(excluded.path)));
    expect(videos.map((e) => e.path), contains(keep.path));
  });

  test('扫描会读取大小与修改时间，供排序使用', () async {
    final temp = await Directory.systemTemp.createTemp('steam_flow_scan_');
    addTearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });
    final file = File('${temp.path}${Platform.pathSeparator}sample.mp4');
    await file.writeAsBytes(List.filled(12, 1));

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.loadSettings();
    final videos = await VideoScanService.scanFolder(temp.path, settings);
    expect(videos, hasLength(1));
    expect(videos.first.sizeBytes, 12);
    expect(videos.first.modifiedTime, isNotNull);
  });
}
