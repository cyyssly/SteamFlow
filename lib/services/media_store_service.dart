import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:steam_flow/models/video_item.dart';

class AlbumInfo {
  final String path;
  final String name;
  final int videoCount;
  final String? thumbnailPath;

  AlbumInfo({
    required this.path,
    required this.name,
    required this.videoCount,
    this.thumbnailPath,
  });
}

class MediaStoreService {
  static const _channel = MethodChannel('com.cyyssly.steamflow/media_store');

  /// 查询设备上所有包含视频的相册（Android 专用）
  static Future<List<AlbumInfo>> getVideoAlbums() async {
    if (!Platform.isAndroid) return [];

    try {
      final result = await _channel.invokeMethod('getVideoAlbums');
      if (result == null) return [];

      final List<dynamic> albums = result as List<dynamic>;
      debugPrint(
        '[MediaStoreService] getVideoAlbums: received ${albums.length} albums from native',
      );
      return albums.map((album) {
        final map = Map<String, dynamic>.from(album as Map);
        return AlbumInfo(
          path: map['path'] as String,
          name: map['name'] as String,
          videoCount: map['videoCount'] as int,
          thumbnailPath: map['thumbnailPath'] as String?,
        );
      }).toList();
    } catch (e) {
      debugPrint(
        '[MediaStoreService] getVideoAlbums failed, falling back to scan: $e',
      );
      // 如果 MethodChannel 不可用，回退到系统目录扫描
      return _fallbackScan();
    }
  }

  /// 请求存储读取权限（Android 专用）
  /// 返回 true 表示已授权
  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod('requestStoragePermission');
      return result == true;
    } catch (_) {
      return true; // 非 Android 或调试模式默认通过
    }
  }

  /// 通过原生端取视频首帧缩略图（Android 专用）。
  ///
  /// [path] 既可以是文件路径，也可以是相册返回的 content:// URI。
  /// 返回的宽高是**真实帧尺寸**（原生侧等比缩放，不裁剪、不留黑边），
  /// 可直接用于推导宽高比。取帧失败时返回 null。
  static Future<({Uint8List bytes, int width, int height})?> getVideoThumbnail(
    String path,
  ) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod('getVideoThumbnail', {
        'path': path,
      });
      if (result == null) return null;
      final map = Map<String, dynamic>.from(result as Map);
      final bytes = map['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      return (
        bytes: bytes,
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('[MediaStoreService] getVideoThumbnail failed: $e');
      return null;
    }
  }

  /// 通过 MediaStore 查询指定文件夹下的所有视频路径（Android 专用）
  ///
  /// 返回的 [VideoItem] 会带上 MediaStore 已索引好的宽高比，
  /// 瀑布流因此无需再解码首帧来取得尺寸（手机上这一步非常慢）。
  /// 若 MediaStore 未索引到尺寸，[VideoItem.aspectRatio] 为 null，
  /// 由调用方回退到取视频首帧推导。
  static Future<List<VideoItem>> getFolderVideos(String folderPath) async {
    if (!Platform.isAndroid) return [];
    try {
      final result = await _channel.invokeMethod('getFolderVideos', {
        'folderPath': folderPath,
      });
      if (result == null) return [];
      final List<dynamic> list = result as List<dynamic>;
      return list.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        final ratio = map['aspectRatio'];
        return VideoItem(
          name: map['name'] as String,
          path: map['path'] as String,
          aspectRatio: ratio is num ? ratio.toDouble() : null,
        );
      }).toList();
    } catch (e) {
      debugPrint('[MediaStoreService] getFolderVideos failed: $e');
      return [];
    }
  }

  /// 把视频移入系统回收站（而不是永久删除）
  /// - Android 11+：通过 MediaStore.createTrashRequest 移入系统回收站（图库可见）
  /// - Android 10 及以下：回退到直接删除
  /// - Windows：通过 PowerShell 调用 Microsoft.VisualBasic 移入回收站
  /// 返回 true 表示操作成功（或已移入回收站）
  static Future<bool> deleteToTrash(List<String> paths) async {
    if (paths.isEmpty) return true;

    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod('deleteToTrash', {
          'paths': paths,
        });
        return result == true;
      } catch (e) {
        debugPrint('[MediaStoreService] deleteToTrash failed: $e');
        // 回退到直接删除
        return _deleteFilesDirectly(paths);
      }
    }

    if (Platform.isWindows) {
      return _deleteToTrashWindows(paths);
    }

    // 其他平台：直接删除
    return _deleteFilesDirectly(paths);
  }

  /// Windows 通过 PowerShell 调用 Microsoft.VisualBasic.FileIO 移入回收站
  static Future<bool> _deleteToTrashWindows(List<String> paths) async {
    try {
      final script =
          '''
Add-Type -AssemblyName Microsoft.VisualBasic
\$paths = @(${paths.map((p) => "'${p.replaceAll("'", "''")}'").join(', ')})
foreach (\$p in \$paths) {
  if (Test-Path \$p) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(\$p, 'OnlyErrorDialogs', 'SendToRecycleBin')
  }
}
''';
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        script,
      ]);
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[MediaStoreService] deleteToTrashWindows failed: $e');
      return _deleteFilesDirectly(paths);
    }
  }

  /// 直接删除文件（回退方案）
  static Future<bool> _deleteFilesDirectly(List<String> paths) async {
    var allOk = true;
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        allOk = false;
      }
    }
    return allOk;
  }

  /// 回退方案：扫描常见视频目录（含子目录）
  static Future<List<AlbumInfo>> _fallbackScan() async {
    if (!Platform.isAndroid) return [];

    const commonDirs = [
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/Movies/ScreenRecorder',
      '/storage/emulated/0/Movies/Telegram',
      '/storage/emulated/0/Movies/WeiXin',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Video',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Video/Sent',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video',
      '/storage/emulated/0/Telegram/Telegram Video',
      '/storage/emulated/0/tencent/MicroMsg/WeiXin',
      '/storage/emulated/0/WeiXin',
      '/storage/emulated/0/Snapchat',
      '/storage/emulated/0/Instagram',
      '/storage/emulated/0/Facebook',
      '/storage/emulated/0/Twitter',
      '/storage/emulated/0/Reddit',
      '/storage/emulated/0/Bluetooth',
    ];

    const supportedExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

    final albums = <AlbumInfo>[];

    Future<({int count, String? firstVideo})> scanDir(String dirPath) async {
      int count = 0;
      String? firstVideo;
      final dir = Directory(dirPath);
      if (!await dir.exists()) return (count: 0, firstVideo: null);
      try {
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (supportedExtensions.contains(ext)) {
              count++;
              firstVideo ??= entity.path;
            }
          }
        }
      } catch (_) {}
      return (count: count, firstVideo: firstVideo);
    }

    // 1. 直接扫描每个常见目录本身
    for (final dirPath in commonDirs) {
      final result = await scanDir(dirPath);
      if (result.count > 0) {
        albums.add(
          AlbumInfo(
            path: dirPath,
            name: dirPath.split('/').last,
            videoCount: result.count,
            thumbnailPath: result.firstVideo,
          ),
        );
      }
    }

    // 2. 对 DCIM、Pictures、Download 等大目录，把每个子目录作为独立相册返回
    const parentDirs = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
    ];

    final seenPaths = albums.map((a) => a.path).toSet();

    for (final parentPath in parentDirs) {
      final parentDir = Directory(parentPath);
      if (!await parentDir.exists()) continue;

      try {
        await for (final subDir in parentDir.list(recursive: false)) {
          if (subDir is Directory) {
            final subResult = await scanDir(subDir.path);
            if (subResult.count > 0 && !seenPaths.contains(subDir.path)) {
              seenPaths.add(subDir.path);
              albums.add(
                AlbumInfo(
                  path: subDir.path,
                  name: subDir.path.split('/').last,
                  videoCount: subResult.count,
                  thumbnailPath: subResult.firstVideo,
                ),
              );
            }
          }
        }
      } catch (_) {}
    }

    // 按视频数量降序排列
    albums.sort((a, b) => b.videoCount.compareTo(a.videoCount));
    return albums;
  }

  // ── 移动 / 复制（支持 Android SAF 方式写入外部目录） ──

  /// 弹出系统目录选择器（Android 用 SAF 选择可写目录，获得返回的 tree uri）。
  /// 其他平台通过 FilePicker 由调用方处理。
  /// @return 选中目录的 tree uri（content://...），取消返回 null
  static Future<String?> pickDestinationDir() async {
    if (!Platform.isAndroid) return null; // 非 Android 由上层用 FilePicker
    try {
      final result = await _channel.invokeMethod('pickDestinationDir');
      return result as String?;
    } catch (e) {
      debugPrint('[MediaStoreService] pickDestinationDir failed: $e');
      return null;
    }
  }

  /// 把 [paths] 中的文件复制到 [destinationUri]（SAF tree uri）。
  /// 返回 true 表示全部成功（或列表为空）。
  static Future<bool> copyFiles(
    String destinationUri,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return true;
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod('copyFiles', {
          'paths': paths,
          'destinationUri': destinationUri,
        });
        return result == true;
      } catch (e) {
        debugPrint('[MediaStoreService] copyFiles failed: $e');
        return false;
      }
    }
    // 非 Android（桌面端）：直接文件复制
    var allOk = true;
    for (final path in paths) {
      try {
        final file = File(path);
        final name = path.split(Platform.pathSeparator).last;
        await file.copy('$destinationUri${Platform.pathSeparator}$name');
      } catch (_) {
        allOk = false;
      }
    }
    return allOk;
  }

  /// 把 [paths] 中的文件移动到 [destinationUri]（SAF tree uri）。
  /// 返回 true 表示全部成功（或列表为空）。
  static Future<bool> moveFiles(
    String destinationUri,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return true;
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod('moveFiles', {
          'paths': paths,
          'destinationUri': destinationUri,
        });
        return result == true;
      } catch (e) {
        debugPrint('[MediaStoreService] moveFiles failed: $e');
        return false;
      }
    }
    // 非 Android（桌面端）：复制后删除源文件
    var allOk = true;
    for (final path in paths) {
      try {
        final file = File(path);
        final name = path.split(Platform.pathSeparator).last;
        await file.copy('$destinationUri${Platform.pathSeparator}$name');
        await file.delete();
      } catch (_) {
        allOk = false;
      }
    }
    return allOk;
  }
}
