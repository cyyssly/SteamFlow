import 'dart:io';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_thumbnail_service.dart';

/// 视频扫描与元数据读取服务
class VideoScanService {
  /// 支持的视频容器格式。
  ///
  /// 只保留现代主流格式：mkv / webm 在 Windows 与 Android 上都能取到首帧，
  /// 更冷门的容器（avi/wmv/flv 等）各平台解码器支持参差不齐，故不纳入。
  static const supportedExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

  /// 扫描文件夹中的视频（Android 走 MediaStore，桌面走文件系统）
  static Future<List<VideoItem>> scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) async {
    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      // MediaStore 已索引好宽高，直接透传，调用方无需再取首帧
      final videos = await MediaStoreService.getFolderVideos(folderPath);
      return videos.where((item) => isSupportedVideo(item.path)).toList();
    }

    // 桌面端使用文件系统 API
    List<File> files = [];
    final dir = Directory(folderPath);
    if (settings.recursiveScan) {
      await for (var entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } else {
      final entities = await dir.list().toList();
      files = entities.whereType<File>().toList();
    }

    return files
        .where((file) => isSupportedVideo(file.path))
        .map(
          (file) => VideoItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  /// 判断是否为支持的视频格式
  static bool isSupportedVideo(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1) return false;
    final ext = path.toLowerCase().substring(dotIndex + 1);
    return supportedExtensions.contains(ext);
  }

  /// 批量读取视频宽高比（宽/高），无法取帧的项为 null。
  ///
  /// 视频的尺寸无法从文件头直接解析出来，必须解码出一帧；
  /// 实现放在 [VideoThumbnailService] 里：一次生成缩略图，
  /// 既拿到宽高比，也把缩略图填进缓存供瀑布流卡片直接显示。
  static Future<List<double?>> readAspectRatios(List<String> paths) =>
      VideoThumbnailService.readAspectRatios(paths);
}
