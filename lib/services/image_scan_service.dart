import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:steam_flow/models/image_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/media_store_service.dart';

/// 图片扫描与元数据读取服务
class ImageScanService {
  static const supportedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
    'tiff',
    'tif',
  };

  /// 扫描文件夹中的图片（Android 走 MediaStore，桌面走文件系统）
  static Future<List<ImageItem>> scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) async {
    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      // MediaStore 已索引好宽高，直接透传，调用方无需再读原图
      final images = await MediaStoreService.getFolderImages(folderPath);
      return images.where((item) => _isSupportedImage(item.path)).toList();
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
        .where((file) => _isSupportedImage(file.path))
        .map(
          (file) => ImageItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  /// 判断是否为支持的图片格式
  static bool _isSupportedImage(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1) return false;
    final ext = path.toLowerCase().substring(dotIndex + 1);
    return supportedExtensions.contains(ext);
  }

  /// 解析宽高比时最多读取的文件头字节数。
  ///
  /// JPEG 的尺寸在 SOF 段、PNG 在 IHDR、WebP 在 VP8X/VP8L 头，
  /// 都位于文件很靠前的位置；256KB 足以覆盖体积较大的 EXIF/ICC 头。
  static const int _headerReadLimit = 256 * 1024;

  /// 头部解析失败时的回退上限。
  ///
  /// TIFF 的尺寸信息可能位于文件末尾的 IFD，无法只靠文件头解析；
  /// 这类格式较为罕见，仅在其体积不超过该上限时才退回整文件读取，
  /// 避免为个别文件付出读取几十 MB 的代价。
  static const int _wholeFileFallbackLimit = 8 * 1024 * 1024;

  /// 批量读取宽高比（宽/高），无法解析的项为 null。
  ///
  /// 关键点：**读取文件这一步也在后台 isolate 里执行**。
  /// 若先在主 isolate 读完全部字节再交给 [compute]，isolate 之间会
  /// 完整拷贝一次数据——手机上一批 30 张原图会产生上百 MB 的无谓拷贝，
  /// 这正是移动端加载明显慢于桌面的主要原因之一。
  static Future<List<double?>> readAspectRatios(List<String> paths) async {
    if (paths.isEmpty) return const [];
    return await compute(_parseAspectRatiosFromPaths, paths);
  }

  /// 后台 isolate 入口：逐张只读文件头并解析宽高比。
  ///
  /// 在单个 isolate 中串行处理，避免为每张图创建 isolate 的开销。
  static List<double?> _parseAspectRatiosFromPaths(List<String> paths) {
    final results = List<double?>.filled(paths.length, null);
    for (var i = 0; i < paths.length; i++) {
      results[i] = _readAspectRatioSync(paths[i]);
    }
    return results;
  }

  /// 同步读取文件头并解析宽高比（仅可在后台 isolate 中调用）。
  static double? _readAspectRatioSync(String path) {
    try {
      final file = File(path);
      final fileLength = file.lengthSync();
      if (fileLength <= 0) return null;

      final readLength = fileLength < _headerReadLimit
          ? fileLength
          : _headerReadLimit;

      var ratio = _tryParseRatio(file, readLength);

      // 头部不足以解析（如 TIFF 的尺寸在文件尾部）时，对中小文件整读一次
      if (ratio == null && fileLength > readLength) {
        if (fileLength <= _wholeFileFallbackLimit) {
          ratio = _tryParseRatio(file, fileLength);
        }
      }
      return ratio;
    } catch (_) {
      return null;
    }
  }

  /// 读取 [length] 字节并尝试解析宽高比，失败返回 null。
  static double? _tryParseRatio(File file, int length) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final bytes = handle.readSync(length);
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info != null && info.height > 0) {
        return info.width / info.height;
      }
    } catch (_) {
    } finally {
      // 无论成功与否都要关闭句柄，避免文件描述符泄漏
      try {
        handle?.closeSync();
      } catch (_) {}
    }
    return null;
  }
}
