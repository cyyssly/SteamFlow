import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/services/lan_client_service.dart';
import 'package:steam_flow/services/lan_server_service.dart';

/// 内网共享的端到端测试：协议、排序、Range、排除、下载续传与一致性校验。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late LanDevice device;
  late Uint8List bigContent;
  late String folderId;
  late List<String> excluded;
  late HttpClient http;

  /// 重新配置并复用同一个服务实例
  Future<void> configureServer({
    bool remoteExclude = true,
    bool remoteCopy = true,
    List<String> Function()? excludedPaths,
    void Function(String path)? onExcludedPath,
  }) {
    return LanServerService.instance.start(
      deviceId: 'it-device',
      deviceName: 'Integration Test',
      folderPaths: () => [temp.path],
      recursiveScan: () => false,
      excludedPaths: excludedPaths ?? () => List.of(excluded),
      remoteExcludeEnabled: () => remoteExclude,
      remoteCopyEnabled: () => remoteCopy,
      onExcludedPath: onExcludedPath ?? (path) => excluded.add(path),
    );
  }

  setUpAll(() async {
    // flutter_test 默认把所有 HTTP 请求替换为 400，这里恢复真实网络
    HttpOverrides.global = null;
    excluded = [];
    http = HttpClient();
    temp = await Directory.systemTemp.createTemp('steam_flow_lan_it_');
    bigContent = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (i) => i % 251),
    );
    final big = File('${temp.path}/a.mp4');
    await big.writeAsBytes(bigContent);
    await File('${temp.path}/b.mp4').writeAsBytes(List.filled(100, 7));
    await File('${temp.path}/c.mp4').writeAsBytes(List.filled(200, 9));
    await big.setLastModified(DateTime(2024, 1, 1));
    await File('${temp.path}/b.mp4').setLastModified(DateTime(2024, 1, 2));
    await File('${temp.path}/c.mp4').setLastModified(DateTime(2024, 1, 3));

    await configureServer();
    device = LanDevice(
      id: 'it-device',
      name: 'Integration Test',
      host: '127.0.0.1',
      port: LanServerService.instance.port,
      folderCount: 1,
      lastSeen: DateTime.now(),
    );
    final folders = await LanClientService.instance.fetchFolders(device);
    folderId = folders!.first.id;
  });

  tearDownAll(() async {
    http.close(force: true);
    await LanServerService.instance.stop();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果
    }
  });

  Future<HttpClientResponse> send(
    String method,
    Uri uri, {
    String? range,
    String? ifRange,
    String? ifNoneMatch,
  }) async {
    final request = await http.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (ifRange != null) {
      request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
    }
    if (ifNoneMatch != null) {
      request.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
    }
    return request.close();
  }

  test('info 暴露远程权限与设备信息', () async {
    final info = await LanClientService.instance.fetchInfo(device);
    expect(info, isNotNull);
    expect(info!['id'], 'it-device');
    expect(info['rx'], isTrue);
    expect(info['rc'], isTrue);
    expect(info['folders'], 1);
  });

  test('文件夹与视频列表可用，按大小/名称排序正确', () async {
    final folders = await LanClientService.instance.fetchFolders(device);
    expect(folders!.first.videoCount, 3);

    final largest = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: folderId,
      sort: 'size',
      order: 'desc',
    );
    expect(largest!.map((e) => e.name).toList(), ['a.mp4', 'c.mp4', 'b.mp4']);

    final nameDesc = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: folderId,
      sort: 'name',
      order: 'desc',
    );
    expect(nameDesc!.map((e) => e.name).toList(), ['c.mp4', 'b.mp4', 'a.mp4']);
  });

  test('随机排序在固定种子下跨页顺序一致', () async {
    final firstPages = <String>[];
    final secondPages = <String>[];
    for (var offset = 0; offset < 3; offset++) {
      final page = await LanClientService.instance.fetchVideos(
        device,
        folderId: folderId,
        offset: offset,
        limit: 1,
        sort: 'random',
        order: 'asc',
        seed: 'fixed-seed',
      );
      firstPages.add(page!.items.first.name);
    }
    for (var offset = 0; offset < 3; offset++) {
      final page = await LanClientService.instance.fetchVideos(
        device,
        folderId: folderId,
        offset: offset,
        limit: 1,
        sort: 'random',
        order: 'asc',
        seed: 'fixed-seed',
      );
      secondPages.add(page!.items.first.name);
    }
    expect(firstPages, secondPages);
    expect(firstPages.toSet(), {'a.mp4', 'b.mp4', 'c.mp4'});
  });

  test('Range / HEAD / 越界 / ETag 缓存校验', () async {
    final page = await LanClientService.instance.fetchVideos(
      device,
      folderId: folderId,
    );
    final item = page!.items.firstWhere((e) => e.name == 'a.mp4');
    final uri = Uri.parse(item.playbackUrl);

    final head = await send('HEAD', uri);
    expect(head.statusCode, HttpStatus.ok);
    expect(head.contentLength, bigContent.length);
    expect(head.headers.value(HttpHeaders.etagHeader), isNotNull);
    final etag = head.headers.value(HttpHeaders.etagHeader)!;
    await head.drain<void>();

    final range = await send('GET', uri, range: 'bytes=100-199');
    expect(range.statusCode, HttpStatus.partialContent);
    expect(
      range.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/${bigContent.length}',
    );
    final bytes = await range.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, bigContent.sublist(100, 200));

    final invalid = await send(
      'GET',
      uri,
      range: 'bytes=${bigContent.length + 10}-',
    );
    expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(
      invalid.headers.value(HttpHeaders.contentRangeHeader),
      'bytes */${bigContent.length}',
    );
    await invalid.drain<void>();

    final notModified = await send('GET', uri, ifNoneMatch: etag);
    expect(notModified.statusCode, HttpStatus.notModified);
    await notModified.drain<void>();
  });

  test('下载进度、完整性与断点续传', () async {
    final page = await LanClientService.instance.fetchVideos(
      device,
      folderId: folderId,
    );
    final item = page!.items.firstWhere((e) => e.name == 'a.mp4');
    final target = File('${temp.path}/download.part');
    addTearDown(() async {
      for (final file in [target, File('${target.path}.meta')]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });

    final progress = <int>[];
    final status = await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) {
        progress.add(received);
        if (total > 0) expect(total, bigContent.length);
      },
    );
    expect(status, DownloadStatus.success);
    expect(await target.readAsBytes(), bigContent);
    expect(progress.first, 0);
    expect(progress.last, bigContent.length);
    expect(await File('${target.path}.meta').exists(), isTrue);

    // 模拟中断：截断到 1MB 后继续下载，应从已有长度续传
    const offset = 1024 * 1024;
    await target.writeAsBytes(bigContent.sublist(0, offset));
    final resumeProgress = <int>[];
    final resumed = await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) => resumeProgress.add(received),
    );
    expect(resumed, DownloadStatus.success);
    expect(resumeProgress.first, offset);
    expect(await target.readAsBytes(), bigContent);

    // 分片已完整时再次下载应直接成功（416 分支）
    final completeProgress = <int>[];
    final complete = await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) => completeProgress.add(received),
    );
    expect(complete, DownloadStatus.success);
    expect(completeProgress.first, bigContent.length);
  });

  test('下载可取消，且分片与元数据保留', () async {
    final page = await LanClientService.instance.fetchVideos(
      device,
      folderId: folderId,
    );
    final item = page!.items.firstWhere((e) => e.name == 'a.mp4');
    final target = File('${temp.path}/cancel.part');
    addTearDown(() async {
      for (final file in [target, File('${target.path}.meta')]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });

    var cancel = false;
    final status = await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) {
        if (received > 0 && received < total) cancel = true;
      },
      isCancelled: () => cancel,
    );
    expect(status, DownloadStatus.cancelled);
    expect(await target.exists(), isTrue);
    expect(await File('${target.path}.meta').exists(), isTrue);
    expect(await target.length(), lessThan(bigContent.length));
  });

  test('远端文件变化时 If-Range 触发整文件重下', () async {
    final page = await LanClientService.instance.fetchVideos(
      device,
      folderId: folderId,
    );
    final item = page!.items.firstWhere((e) => e.name == 'a.mp4');
    final target = File('${temp.path}/changed.part');
    addTearDown(() async {
      for (final file in [target, File('${target.path}.meta')]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });

    // 先下载一部分并保留 meta（模拟中断）
    var cancel = false;
    await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) {
        if (received > 0 && received < total) cancel = true;
      },
      isCancelled: () => cancel,
    );
    expect(await target.exists(), isTrue);

    // 替换远端文件（内容与大小均变化）
    final newContent = Uint8List.fromList(
      List<int>.generate(2 * 1024 * 1024, (i) => (i * 3) % 251),
    );
    final big = File('${temp.path}/a.mp4');
    await big.writeAsBytes(newContent);
    await big.setLastModified(DateTime(2025, 1, 1));

    final progress = <int>[];
    final status = await LanClientService.instance.downloadVideo(
      item.playbackUrl,
      target,
      onProgress: (received, total) => progress.add(received),
    );
    expect(status, DownloadStatus.success);
    // 从头开始下载，而不是在旧分片后面追加
    expect(progress.first, 0);
    expect(await target.readAsBytes(), newContent);
  });

  test('远程排除：权限、幂等与路径穿越防护', () async {
    final before = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: folderId,
    );
    final item = before!.firstWhere((e) => e.name == 'b.mp4');
    final relativeId = item.remoteId!.substring(folderId.length + 1);

    // 开启权限时成功，重复请求幂等
    expect(
      await LanClientService.instance.excludeVideo(
        device,
        folderId: folderId,
        id: relativeId,
      ),
      isTrue,
    );
    expect(
      await LanClientService.instance.excludeVideo(
        device,
        folderId: folderId,
        id: relativeId,
      ),
      isTrue,
    );

    final after = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: folderId,
    );
    expect(after!.map((e) => e.name), isNot(contains('b.mp4')));

    // 路径穿越必须被拒绝
    expect(
      await LanClientService.instance.excludeVideo(
        device,
        folderId: folderId,
        id: '../outside.mp4',
      ),
      isFalse,
    );

    // 关闭权限后拒绝
    await configureServer(remoteExclude: false);
    final children = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: folderId,
    );
    final stillThere = children!.firstWhere((e) => e.name == 'c.mp4');
    expect(
      await LanClientService.instance.excludeVideo(
        device,
        folderId: folderId,
        id: stillThere.remoteId!.substring(folderId.length + 1),
      ),
      isFalse,
    );

    // 恢复权限，避免影响后续用例
    await configureServer();
  });
}
