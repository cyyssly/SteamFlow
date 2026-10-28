import 'dart:io';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_formats.dart';
import 'package:steam_flow/services/video_thumbnail_service.dart';

/// 视频扫描与元数据读取服务
class VideoScanService {
  /// 扫描文件夹中的视频（Android 走 MediaStore，桌面走文件系统）
  ///
  /// 扫描结果会剔除 [SettingsProvider.excludedPaths] 中记录的视频：
  /// 排除操作只是把路径记进设置，若不在扫描时过滤，退出页面重新进入后
  /// 被排除的视频会再次出现。
  ///
  /// [recursiveOverride] 为非 null 时强制指定是否递归扫描；为 null 时跟随
  /// [SettingsProvider.recursiveScan]。文件直开场景需"只扫当前目录"，
  /// 传 `false` 即可独立于全局设置。
  static Future<List<VideoItem>> scanFolder(
    String folderPath,
    SettingsProvider settings, {
    bool? recursiveOverride,
  }) async {
    // Windows 文件路径不区分大小写，统一转小写比较，避免因大小写差异漏过滤
    final excluded = {
      for (final path in settings.excludedPaths)
        Platform.isWindows ? path.toLowerCase() : path,
    };
    bool notExcluded(VideoItem item) => !excluded.contains(
      Platform.isWindows ? item.path.toLowerCase() : item.path,
    );

    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      // MediaStore 已索引好宽高，直接透传，调用方无需再取首帧
      final videos = await MediaStoreService.getFolderVideos(folderPath);
      return videos
          .where((item) => isSupportedVideoPath(item.path) && notExcluded(item))
          .toList();
    }

    // 桌面端使用文件系统 API
    List<File> files = [];
    final dir = Directory(folderPath);
    final recursive = recursiveOverride ?? settings.recursiveScan;
    if (recursive) {
      await for (var entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } else {
      final entities = await dir.list().toList();
      files = entities.whereType<File>().toList();
    }

    final items = <VideoItem>[];
    for (final file in files) {
      if (!isSupportedVideoPath(file.path)) continue;
      // 文件大小与修改时间在此读入，避免瀑布流卡片在 build 里同步读盘。
      // 分辨率此处未知（无法从文件头解析），由后续取帧时（[readSizes]）补齐。
      DateTime? modifiedTime;
      int? sizeBytes;
      try {
        final stat = await file.stat();
        modifiedTime = stat.modified;
        sizeBytes = stat.size;
      } catch (_) {
        // 文件被占用/权限不足时忽略，对应信息显示为「未知」
      }
      items.add(
        VideoItem(
          name: file.path.split(Platform.pathSeparator).last,
          path: file.path,
          modifiedTime: modifiedTime,
          sizeBytes: sizeBytes,
        ),
      );
    }
    return items.where(notExcluded).toList();
  }

  /// 批量读取视频宽高比（宽/高），无法取帧的项为 null。
  ///
  /// 视频的尺寸无法从文件头直接解析出来，必须解码出一帧；
  /// 实现放在 [VideoThumbnailService] 里：一次生成缩略图，
  /// 既拿到宽高比，也把缩略图填进缓存供瀑布流卡片直接显示。
  static Future<List<double?>> readAspectRatios(List<String> paths) =>
      VideoThumbnailService.readAspectRatios(paths);

  /// 批量读取视频的宽高比与真实分辨率（同时把缩略图填入缓存）。
  static Future<List<VideoFrameInfo>> readSizes(List<String> paths) =>
      VideoThumbnailService.readSizes(paths);
}
