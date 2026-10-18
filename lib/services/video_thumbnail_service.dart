import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_thumbnail_win.dart';

/// 复用 [VideoThumbnail] 作为统一的返回值类型。
///
/// 该类型定义在 [video_thumbnail_win] 里（那个文件刻意不依赖 Flutter，
/// 以便用 `dart run` 独立验证原生取帧），这里只是转发，
/// 免得调用方到处 import 底层实现。
export 'video_thumbnail_win.dart' show VideoThumbnail;

/// 视频缩略图服务：统一封装各平台的取帧方式，并做内存缓存与去重。
///
/// - Windows：Shell 缩略图接口（[windowsVideoThumbnailSync]），整批丢进后台 isolate；
/// - Android：走原生 MediaStore / MediaMetadataRetriever（原生侧自行切线程）。
///
/// 缩略图同时用于两件事：瀑布流卡片显示，以及由帧尺寸推导宽高比
/// （视频的宽高比无法从文件头解析出来，必须先解码出一帧）。
class VideoThumbnailService {
  VideoThumbnailService._();

  /// 路径 -> 缩略图（含生成失败的 null，避免对同一个文件反复重试）。
  static final Map<String, VideoThumbnail?> _cache = {};

  /// 同一路径正在进行的请求，供并发调用共享同一个 Future。
  static final Map<String, Future<VideoThumbnail?>> _pending = {};

  /// 同步读取已缓存的缩略图；未生成时返回 null，调用方据此决定是否等待。
  static VideoThumbnail? cached(String path) => _cache[path];

  /// 取单个视频的缩略图。
  static Future<VideoThumbnail?> thumbnailFor(String path) {
    if (_cache.containsKey(path)) {
      return Future.value(_cache[path]);
    }
    final pending = _pending[path];
    if (pending != null) return pending;
    final future = _load(path);
    _pending[path] = future;
    return future;
  }

  /// 批量读取宽高比（宽/高），无法生成缩略图的项为 null。
  ///
  /// 同时把缩略图填进缓存，调用方后续渲染卡片时可直接命中，
  /// 不会出现「先渲染成正方形、再跳变成真实比例」的抖动。
  static Future<List<double?>> readAspectRatios(List<String> paths) async {
    if (paths.isEmpty) return const [];

    final thumbs = List<VideoThumbnail?>.filled(paths.length, null);
    final missingPaths = <String>[];
    final missingIndexes = <int>[];

    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (_cache.containsKey(path)) {
        thumbs[i] = _cache[path];
      } else {
        missingPaths.add(path);
        missingIndexes.add(i);
      }
    }

    if (missingPaths.isNotEmpty) {
      final loaded = await _loadBatch(missingPaths);
      for (var k = 0; k < missingPaths.length; k++) {
        _cache[missingPaths[k]] = loaded[k];
        thumbs[missingIndexes[k]] = loaded[k];
      }
    }

    return [for (final thumb in thumbs) thumb?.aspectRatio];
  }

  static Future<VideoThumbnail?> _load(String path) async {
    VideoThumbnail? result;
    try {
      final batch = await _loadBatch([path]);
      result = batch.first;
    } finally {
      _cache[path] = result;
      _pending.remove(path);
    }
    return result;
  }

  /// 各平台的批量取帧实现。
  static Future<List<VideoThumbnail?>> _loadBatch(List<String> paths) async {
    try {
      if (Platform.isWindows) {
        // Shell 的 COM 调用是阻塞式的，必须放到后台 isolate。
        // 整批一次处理：一批 30 个文件若各自新建 isolate，
        // 开销远大于取帧本身。
        return await Isolate.run(() => windowsVideoThumbnailsSync(paths));
      }
      if (Platform.isAndroid) {
        return await Future.wait(paths.map(_loadAndroid));
      }
    } catch (e) {
      debugPrint('[VideoThumbnailService] 批量取帧失败: $e');
    }
    return List<VideoThumbnail?>.filled(paths.length, null);
  }

  /// Android 通过原生接口取帧，路径既可以是文件路径也可以是 content:// URI。
  static Future<VideoThumbnail?> _loadAndroid(String path) async {
    try {
      final data = await MediaStoreService.getVideoThumbnail(path);
      if (data == null) return null;
      return VideoThumbnail(
        bytes: data.bytes,
        width: data.width,
        height: data.height,
      );
    } catch (e) {
      debugPrint('[VideoThumbnailService] 原生取帧失败: $path: $e');
      return null;
    }
  }
}
