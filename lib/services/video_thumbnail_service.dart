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

/// 一次取帧得到的视频信息：宽高比与真实分辨率（不可用时为 null）。
class VideoFrameInfo {
  final double? aspectRatio;
  final int? width;
  final int? height;

  const VideoFrameInfo({this.aspectRatio, this.width, this.height});
}

/// 视频缩略图服务：统一封装各平台的取帧方式，并做内存缓存与去重。
///
/// - Windows：Shell 缩略图接口（[windowsVideoThumbnailSync]），整批丢进后台 isolate；
/// - Android：走原生 MediaStore / MediaMetadataRetriever（原生侧自行切线程）。
///
/// 缩略图同时用于两件事：瀑布流卡片显示，以及由帧尺寸推导宽高比
/// （视频的宽高比无法从文件头解析出来，必须先解码出一帧）。
class VideoThumbnailService {
  VideoThumbnailService._();

  /// 缩略图长边的档位（物理像素）。
  ///
  /// 按卡片实际需要的像素就近向上取档：既保证放大到 4K 也清晰，
  /// 又不会因为窗口每次微调尺寸就重新解码一遍。
  static const List<int> sizeBuckets = [512, 768, 1024, 1536];

  /// 调用方未指定尺寸时使用的长边（与旧版本行为一致）。
  static const int defaultMaxSize = kDefaultThumbnailMaxSize;

  /// 把需要的像素数向上取到最近的档位，超过最大档位时取最大档。
  static int bucketFor(int neededPixels) {
    for (final bucket in sizeBuckets) {
      if (bucket >= neededPixels) return bucket;
    }
    return sizeBuckets.last;
  }

  /// 路径 -> 缩略图（含生成失败的 null，避免对同一个文件反复重试）。
  static final Map<String, VideoThumbnail?> _cache = {};

  /// 路径 -> 生成这张缩略图时请求的长边，用于判断是否需要换成更清晰的。
  static final Map<String, int> _cacheMaxSize = {};

  /// 同一路径 + 同一尺寸正在进行的请求，供并发调用共享同一个 Future。
  static final Map<String, Future<VideoThumbnail?>> _pending = {};

  /// 同步读取已缓存的缩略图；未生成、生成失败、或缓存尺寸小于 [maxSize]
  /// 时返回 null，调用方据此决定是否等待更大的一张。
  static VideoThumbnail? cached(
    String path, {
    int maxSize = defaultMaxSize,
  }) {
    if (!_cache.containsKey(path)) return null;
    final thumb = _cache[path];
    if (thumb == null) return null; // 已知失败，不再重试
    return (_cacheMaxSize[path] ?? 0) >= maxSize ? thumb : null;
  }

  /// 取单个视频的缩略图。
  static Future<VideoThumbnail?> thumbnailFor(
    String path, {
    int maxSize = defaultMaxSize,
  }) {
    final usable = cached(path, maxSize: maxSize);
    if (usable != null) return Future.value(usable);
    // 已经确认这个文件拿不到缩略图：直接复用失败结果
    if (_cache.containsKey(path) && _cache[path] == null) {
      return Future.value(null);
    }
    final key = '$path|$maxSize';
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _load(path, maxSize);
    _pending[key] = future;
    return future;
  }

  /// 批量读取宽高比（宽/高），无法生成缩略图的项为 null。
  ///
  /// 同时把缩略图填进缓存，调用方后续渲染卡片时可直接命中，
  /// 不会出现「先渲染成正方形、再跳变成真实比例」的抖动。
  static Future<List<double?>> readAspectRatios(
    List<String> paths, {
    int maxSize = defaultMaxSize,
  }) async {
    if (paths.isEmpty) return const [];
    final thumbs = await _loadAll(paths, maxSize);
    return [for (final thumb in thumbs) thumb?.aspectRatio];
  }

  /// 批量读取宽高比与真实分辨率（同时把缩略图填进缓存）。
  ///
  /// 真实分辨率只有 Windows 端能拿到（见 `VideoThumbnail.sourceWidth`）：
  /// 缩略图会被等比缩放，其位图尺寸只能反映宽高比，不能当分辨率用，
  /// 因此 Android 端此处为 null，分辨率改由 MediaStore 直接提供。
  static Future<List<VideoFrameInfo>> readSizes(
    List<String> paths, {
    int maxSize = defaultMaxSize,
  }) async {
    if (paths.isEmpty) return const [];
    final thumbs = await _loadAll(paths, maxSize);
    return [
      for (final thumb in thumbs)
        VideoFrameInfo(
          aspectRatio: thumb?.aspectRatio,
          width: thumb?.sourceWidth,
          height: thumb?.sourceHeight,
        ),
    ];
  }

  /// 逐项取缩略图（命中足够大的缓存则直接复用），未命中部分整批加载。
  static Future<List<VideoThumbnail?>> _loadAll(
    List<String> paths,
    int maxSize,
  ) async {
    final thumbs = List<VideoThumbnail?>.filled(paths.length, null);
    final missingPaths = <String>[];
    final missingIndexes = <int>[];

    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (!_cache.containsKey(path)) {
        missingPaths.add(path);
        missingIndexes.add(i);
        continue;
      }
      if (_cache[path] == null) {
        thumbs[i] = null; // 已知失败，直接复用
        continue;
      }
      final usable = cached(path, maxSize: maxSize);
      if (usable != null) {
        thumbs[i] = usable;
      } else {
        // 缓存里那张太小（窗口变大 / 高 DPI），重新取一张更清晰的
        missingPaths.add(path);
        missingIndexes.add(i);
      }
    }

    if (missingPaths.isNotEmpty) {
      final loaded = await _loadBatch(missingPaths, maxSize);
      for (var k = 0; k < missingPaths.length; k++) {
        _cache[missingPaths[k]] = loaded[k];
        if (loaded[k] == null) {
          _cacheMaxSize.remove(missingPaths[k]);
        } else {
          _cacheMaxSize[missingPaths[k]] = maxSize;
        }
        thumbs[missingIndexes[k]] = loaded[k];
      }
    }

    return thumbs;
  }

  static Future<VideoThumbnail?> _load(String path, int maxSize) async {
    VideoThumbnail? result;
    try {
      final batch = await _loadBatch([path], maxSize);
      result = batch.first;
    } finally {
      _cache[path] = result;
      if (result == null) {
        _cacheMaxSize.remove(path);
      } else {
        _cacheMaxSize[path] = maxSize;
      }
      _pending.remove('$path|$maxSize');
    }
    return result;
  }

  /// 各平台的批量取帧实现。
  static Future<List<VideoThumbnail?>> _loadBatch(
    List<String> paths,
    int maxSize,
  ) async {
    try {
      if (Platform.isWindows) {
        // Shell 的 COM 调用是阻塞式的，必须放到后台 isolate。
        // 整批一次处理：一批 30 个文件若各自新建 isolate，
        // 开销远大于取帧本身。
        return await Isolate.run(
          () => windowsVideoThumbnailsSync(paths, maxSize: maxSize),
        );
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
