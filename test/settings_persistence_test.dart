import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已排除路径加载去重，单条移除会清掉全部重复项', () async {
    SharedPreferences.setMockInitialValues({
      'excludedPaths': json.encode(['/a.mp4', '/a.mp4', '/b.mp4']),
    });
    final settings = SettingsProvider();
    await settings.loadSettings();
    expect(settings.excludedPaths, ['/a.mp4', '/b.mp4']);

    settings.removeExcludedPath('/a.mp4');
    expect(settings.excludedPaths, ['/b.mp4']);
  });

  test('批量恢复只移除目标路径且保持其余顺序', () async {
    SharedPreferences.setMockInitialValues({
      'excludedPaths': json.encode(['/a.mp4', '/b.mp4', '/c.mp4', '/b.mp4']),
    });
    final settings = SettingsProvider();
    await settings.loadSettings();
    expect(settings.excludedPaths, ['/a.mp4', '/b.mp4', '/c.mp4']);

    settings.removeExcludedPaths(['/b.mp4', '/c.mp4']);
    expect(settings.excludedPaths, ['/a.mp4']);
  });

  test('排序方式与上次复制目录可持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final first = SettingsProvider();
    await first.loadSettings();
    first.setLocalSort('/videos', 'sizeLargest');
    first.setSharedSort('dev/folder', 'timeNewest');
    first.setLastCopyDestination('D:/target');
    // 等待异步落盘完成
    await Future<void>.delayed(Duration.zero);

    final second = SettingsProvider();
    await second.loadSettings();
    expect(second.localSortFor('/videos'), 'sizeLargest');
    expect(second.sharedSortFor('dev/folder'), 'timeNewest');
    expect(second.lastCopyDestination, 'D:/target');
  });

  test('损坏的排序存储不会导致启动异常', () async {
    SharedPreferences.setMockInitialValues({
      'localSortModes': '{not-json',
      'sharedSortModes': '[]',
    });
    final settings = SettingsProvider();
    await settings.loadSettings();
    expect(settings.localSortFor('/x'), isNull);
    expect(settings.sharedSortFor('y'), isNull);
  });

  test('播放顺序新增项追加在末尾', () {
    expect(PlayOrder.sizeLargest.index, 6);
    expect(PlayOrder.sizeSmallest.index, 7);
    // 旧版本已持久化的下标含义保持不变
    expect(PlayOrder.sequential.index, 0);
    expect(PlayOrder.reverseSequential.index, 5);
  });
}
