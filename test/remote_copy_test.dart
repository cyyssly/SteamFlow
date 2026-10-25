import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:steam_flow/services/remote_copy_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('桌面端重名目标自动追加序号', () async {
    final temp = await Directory.systemTemp.createTemp('steam_flow_copy_');
    addTearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });
    await File('${temp.path}${Platform.pathSeparator}video.mp4').create();
    await File(
      '${temp.path}${Platform.pathSeparator}video_1.mp4',
    ).create();

    final target = await RemoteCopyService.uniqueDesktopTarget(
      temp.path,
      'video.mp4',
    );
    expect(
      target,
      '${temp.path}${Platform.pathSeparator}video_2.mp4',
    );

    // 无扩展名文件同样适用
    await File('${temp.path}${Platform.pathSeparator}README').create();
    final noExt = await RemoteCopyService.uniqueDesktopTarget(
      temp.path,
      'README',
    );
    expect(noExt, '${temp.path}${Platform.pathSeparator}README_1');
  });

  test('复制服务空闲时可接受任务', () {
    expect(RemoteCopyService.isCopying, isFalse);
  });
}
