import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/services/lan_protocol.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_formats.dart';
import 'package:steam_flow/services/video_thumbnail_service.dart';

/// 缩略图转码任务（可在后台 isolate 执行）
class _ThumbTask {
  final Uint8List bytes;
  final int width;

  const _ThumbTask(this.bytes, this.width);
}

/// 顶层函数才能作为 [compute] 的入口
Uint8List? _encodeThumbnail(_ThumbTask task) {
  try {
    final decoded = img.decodeImage(task.bytes);
    if (decoded == null) return null;
    final resized = decoded.width <= task.width
        ? decoded
        : img.copyResize(
            decoded,
            width: task.width,
            interpolation: img.Interpolation.average,
          );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  } catch (_) {
    return null;
  }
}

class _FolderCache {
  final List<VideoItem> videos;
  final DateTime timestamp;

  const _FolderCache(this.videos, this.timestamp);
}

/// 排序后的视频列表缓存（按排序参数区分）
///
/// 按时间/大小排序需要全量元数据；同一排序参数下的连续分页请求直接复用结果。
class _SortedCache {
  final List<VideoItem> videos;
  final DateTime timestamp;

  const _SortedCache(this.videos, this.timestamp);
}

/// 局域网 HTTP 视频服务（只读）。
///
/// 提供设备信息、共享目录列表、分页视频元数据、首帧缩略图与原片。
/// 原片接口完整支持 `Range` / `HEAD`，供播放器起播与拖动进度条。
class LanServerService {
  static final LanServerService instance = LanServerService._();

  LanServerService._();

  /// 目录扫描结果缓存时长。
  static const Duration _scanCacheDuration = Duration(seconds: 60);

  /// 排序结果缓存上限，避免反复切换排序导致缓存无限增长
  static const int _maxSortCacheEntries = 24;

  HttpServer? _server;
  int _port = LanProtocol.defaultHttpPort;
  String _deviceId = '';
  String _deviceName = 'SteamFlow';
  List<String> Function()? _folderPaths;
  bool Function()? _recursiveScan;
  List<String> Function()? _excludedPaths;
  bool Function()? _remoteExcludeEnabled;
  bool Function()? _remoteCopyEnabled;
  void Function(String path)? _onExcludedPath;

  final Map<String, _FolderCache> _folderCache = {};

  /// 排序结果缓存，键为「目录|排序方式|方向|随机种子」
  final Map<String, _SortedCache> _sortCache = {};

  /// 已取过帧的视频信息缓存，避免分页时重复解码同一批文件
  final Map<String, VideoFrameInfo?> _frameCache = {};

  bool get isRunning => _server != null;

  int get port => _server?.port ?? _port;

  /// 启动（或更新配置）服务。
  ///
  /// [excludedPaths] 返回本机已被排除播放的视频，这类文件不会对外列出。
  Future<void> start({
    required String deviceId,
    required String deviceName,
    required List<String> Function() folderPaths,
    required bool Function() recursiveScan,
    required List<String> Function() excludedPaths,
    bool Function()? remoteExcludeEnabled,
    bool Function()? remoteCopyEnabled,
    void Function(String path)? onExcludedPath,
  }) async {
    _deviceId = deviceId;
    _deviceName = deviceName;
    _folderPaths = folderPaths;
    _recursiveScan = recursiveScan;
    _excludedPaths = excludedPaths;
    _remoteExcludeEnabled = remoteExcludeEnabled;
    _remoteCopyEnabled = remoteCopyEnabled;
    _onExcludedPath = onExcludedPath;

    if (_server != null) return;

    HttpServer? server;
    var candidate = LanProtocol.defaultHttpPort;
    for (var i = 0; i < 8 && server == null; i++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, candidate);
      } on SocketException {
        candidate++;
      }
    }
    if (server == null) {
      throw const SocketException('LAN server port unavailable');
    }

    _server = server;
    _port = server.port;
    server.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _folderCache.clear();
    _sortCache.clear();
    _frameCache.clear();
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final uri = request.uri;
      switch (uri.path) {
        case LanProtocol.infoPath:
          await _writeJson(response, _info());
          return;
        case LanProtocol.foldersPath:
          await _writeJson(response, {'folders': await _foldersJson()});
          return;
        case LanProtocol.videosPath:
          await _serveVideos(uri, response);
          return;
        case LanProtocol.videoPath:
          await _serveVideo(request, uri, response);
          return;
        case LanProtocol.thumbPath:
          await _serveThumb(uri, response);
          return;
        case LanProtocol.excludePath:
          await _serveExclude(request, uri, response);
          return;
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('Not Found');
          await response.close();
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.write('Server Error');
        await response.close();
      } catch (_) {
        // 连接已被对端关闭，忽略
      }
    }
  }

  Map<String, Object?> _info() {
    return {
      'v': LanProtocol.version,
      'id': _deviceId,
      'name': _deviceName,
      'port': _port,
      'folders': _folderPaths?.call().length ?? 0,
      'platform': Platform.operatingSystem,
      // 允许远端执行的操作，客户端据此决定按钮是否可用
      'rx': _remoteExcludeEnabled?.call() ?? false,
      'rc': _remoteCopyEnabled?.call() ?? false,
    };
  }

  Future<List<Map<String, Object?>>> _foldersJson() async {
    final paths = _folderPaths?.call() ?? const <String>[];
    final result = <Map<String, Object?>>[];
    for (final path in paths) {
      final videos = await _videosForPath(path);
      result.add({
        'id': folderIdFor(path),
        'name': _folderName(path),
        'count': videos.length,
      });
    }
    return result;
  }

  Future<List<VideoItem>> _videosForPath(String folder) async {
    final cached = _folderCache[folder];
    if (cached != null &&
        DateTime.now().difference(cached.timestamp) < _scanCacheDuration) {
      return cached.videos;
    }
    final videos = await _scanFolder(folder);
    // 目录内容变化后，旧的排序结果不再有效
    _sortCache.removeWhere((key, _) => key.startsWith('$folder|'));
    _folderCache[folder] = _FolderCache(videos, DateTime.now());
    return videos;
  }

  Future<List<VideoItem>> _scanFolder(String folder) async {
    // Android 走 MediaStore：绕过 Scoped Storage，并复用其已索引的宽高与大小
    if (Platform.isAndroid) {
      final items = await MediaStoreService.getFolderVideos(folder);
      return items
          .where(
            (item) =>
                isSupportedVideoPath(item.path) && !_isExcluded(item.path),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    final dir = Directory(folder);
    if (!await dir.exists()) return const [];

    final recursive = _recursiveScan?.call() ?? true;
    final files = <File>[];
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is File &&
          isSupportedVideoPath(entity.path) &&
          !_isExcluded(entity.path)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final items = <VideoItem>[];
    for (final file in files) {
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
    return items;
  }

  /// 按查询参数返回排好序的视频列表。
  ///
  /// 支持 `sort=name|time|size|random` 与 `order=asc|desc`；
  /// 不传 `sort` 时保持目录扫描的默认顺序。
  /// 随机排序用 `seed` 保证同一次浏览的各页顺序一致。
  Future<_SortedCache> _videosForServe(
    String root, {
    String? sort,
    required String order,
    required String seed,
  }) async {
    final videos = await _videosForPath(root);
    if (sort == null || sort.isEmpty) {
      return _SortedCache(videos, DateTime.now());
    }

    final key = '$root|$sort|$order|$seed';
    final cached = _sortCache[key];
    if (cached != null) {
      if (DateTime.now().difference(cached.timestamp) < _scanCacheDuration) {
        return cached;
      }
      _sortCache.remove(key);
    }

    final descending = order == 'desc';
    List<VideoItem> sorted;

    switch (sort) {
      case 'random':
        sorted = [...videos]
          ..sort(
            (a, b) =>
                _hash('$seed:${a.path}').compareTo(_hash('$seed:${b.path}')),
          );
        break;
      case 'name':
        sorted = [
          ...videos,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (descending) sorted = sorted.reversed.toList();
        break;
      case 'size':
        sorted = [...videos]
          ..sort((a, b) => (a.sizeBytes ?? 0).compareTo(b.sizeBytes ?? 0));
        if (descending) sorted = sorted.reversed.toList();
        break;
      case 'time':
        sorted = [...videos]
          ..sort(
            (a, b) => (a.modifiedTime?.millisecondsSinceEpoch ?? 0).compareTo(
              b.modifiedTime?.millisecondsSinceEpoch ?? 0,
            ),
          );
        if (descending) sorted = sorted.reversed.toList();
        break;
      default:
        sorted = videos;
    }

    final result = _SortedCache(sorted, DateTime.now());
    if (_sortCache.length > _maxSortCacheEntries) {
      _sortCache.remove(_sortCache.keys.first);
    }
    _sortCache[key] = result;
    return result;
  }

  Future<void> _serveVideos(Uri uri, HttpResponse response) async {
    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      response.write('Folder Not Found');
      await response.close();
      return;
    }

    final offset = (int.tryParse(uri.queryParameters['offset'] ?? '') ?? 0)
        .clamp(0, 1 << 30);
    final limit = (int.tryParse(uri.queryParameters['limit'] ?? '') ?? 60)
        .clamp(1, 500);

    final serve = await _videosForServe(
      root,
      sort: uri.queryParameters['sort'],
      order: uri.queryParameters['order'] == 'desc' ? 'desc' : 'asc',
      seed: uri.queryParameters['seed'] ?? '',
    );
    final videos = serve.videos;
    final page = videos.skip(offset).take(limit).toList();
    final frameInfos = await _frameInfosForPage(page);

    final itemsJson = <Map<String, Object?>>[];
    for (var i = 0; i < page.length; i++) {
      final item = page[i];
      final info = frameInfos[i];
      itemsJson.add({
        'id': _relativeTo(root, item.path),
        'name': item.name,
        'size': item.sizeBytes,
        'mtime': item.modifiedTime?.millisecondsSinceEpoch,
        'width': info?.width ?? item.width,
        'height': info?.height ?? item.height,
        'aspect': info?.aspectRatio ?? item.aspectRatio,
      });
    }

    await _writeJson(response, {
      'total': videos.length,
      'offset': offset,
      'items': itemsJson,
    });
  }

  /// 为当前页补齐帧信息（宽高比/真实分辨率）。
  ///
  /// 桌面端扫描不到尺寸，必须解码一帧；取帧结果同时写入
  /// [VideoThumbnailService] 的缓存，随后请求同一视频的缩略图可直接命中。
  Future<List<VideoFrameInfo?>> _frameInfosForPage(List<VideoItem> page) async {
    final result = List<VideoFrameInfo?>.filled(page.length, null);
    final pendingPaths = <String>[];
    final pendingIndexes = <int>[];

    for (var i = 0; i < page.length; i++) {
      final item = page[i];
      if (item.width != null && item.height != null && item.height! > 0) {
        result[i] = VideoFrameInfo(
          aspectRatio: item.width! / item.height!,
          width: item.width,
          height: item.height,
        );
        _frameCache[item.path] = result[i];
      } else if (item.aspectRatio != null) {
        result[i] = VideoFrameInfo(aspectRatio: item.aspectRatio);
        _frameCache[item.path] = result[i];
      } else if (_frameCache.containsKey(item.path)) {
        result[i] = _frameCache[item.path];
      } else {
        pendingPaths.add(item.path);
        pendingIndexes.add(i);
      }
    }

    if (pendingPaths.isNotEmpty) {
      final infos = await VideoThumbnailService.readSizes(pendingPaths);
      for (var i = 0; i < pendingPaths.length; i++) {
        result[pendingIndexes[i]] = infos[i];
        _frameCache[pendingPaths[i]] = infos[i];
      }
    }
    return result;
  }

  /// 原片接口：支持 `Range` 与 `HEAD`。
  ///
  /// 播放器起播与拖动进度条都会发送 `Range: bytes=...`，
  /// 必须返回 206 + `Content-Range`，否则表现为无法跳转或反复重连。
  Future<void> _serveVideo(
    HttpRequest request,
    Uri uri,
    HttpResponse response,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fullPath = _resolveWithin(root, uri.queryParameters['id'] ?? '');
    if (fullPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    final file = File(fullPath);
    FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (stat.type == FileSystemEntityType.notFound) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final size = stat.size;
    final etag = '"${stat.modified.millisecondsSinceEpoch}-$size"';
    response.headers.contentType = _contentType(fullPath);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.etagHeader, etag);
    response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=3600',
    );

    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    final isHead = request.method == 'HEAD';
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

    // If-Range 不匹配：客户端的续传分片来自旧版本文件，忽略 Range 返回完整内容
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    if (rangeHeader != null &&
        rangeHeader.isNotEmpty &&
        ifRange != null &&
        ifRange != etag) {
      response.contentLength = size;
      if (!isHead) await response.addStream(file.openRead());
      await response.close();
      return;
    }

    if (rangeHeader == null || rangeHeader.isEmpty) {
      response.contentLength = size;
      if (!isHead) await response.addStream(file.openRead());
      await response.close();
      return;
    }

    final range = _parseRange(rangeHeader, size);
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
      response.contentLength = 0;
      await response.close();
      return;
    }

    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${range.start}-${range.end}/$size',
    );
    response.contentLength = range.end - range.start + 1;
    if (!isHead) {
      await response.addStream(file.openRead(range.start, range.end + 1));
    }
    await response.close();
  }

  /// 解析单段 `Range` 请求头，非法时返回 null（调用方回 416）。
  ///
  /// 支持 `bytes=start-end`、`bytes=start-`、`bytes=-suffix` 三种形式；
  /// 多段范围只取第一段（mpv/浏览器不会依赖多段响应）。
  static ({int start, int end})? _parseRange(String header, int size) {
    if (size <= 0) return null;
    if (!header.startsWith('bytes=')) return null;
    final spec = header.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash == -1) return null;

    final startText = spec.substring(0, dash).trim();
    final endText = spec.substring(dash + 1).trim();

    int start;
    int end;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      start = size - suffix;
      if (start < 0) start = 0;
      end = size - 1;
    } else {
      final parsedStart = int.tryParse(startText);
      if (parsedStart == null || parsedStart < 0 || parsedStart >= size) {
        return null;
      }
      start = parsedStart;
      if (endText.isEmpty) {
        end = size - 1;
      } else {
        final parsedEnd = int.tryParse(endText);
        if (parsedEnd == null || parsedEnd < start) return null;
        end = parsedEnd >= size ? size - 1 : parsedEnd;
      }
    }
    return (start: start, end: end);
  }

  /// 缩略图接口：取首帧并转码为指定宽度的 JPEG。
  ///
  /// 取帧复用 [VideoThumbnailService]（各平台原生取帧，失败返回 null），
  /// 转码结果按「路径+修改时间+宽度」落盘缓存。
  Future<void> _serveThumb(Uri uri, HttpResponse response) async {
    final root = _folderById(uri.queryParameters['folder']);
    if (root == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fullPath = _resolveWithin(root, uri.queryParameters['id'] ?? '');
    if (fullPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    final width = (int.tryParse(uri.queryParameters['w'] ?? '') ?? 400).clamp(
      64,
      1024,
    );

    var mtime = 0;
    try {
      final stat = await File(fullPath).stat();
      if (stat.type != FileSystemEntityType.notFound) {
        mtime = stat.modified.millisecondsSinceEpoch;
      }
    } catch (_) {
      // 元数据不可用不影响取帧，缓存键退化为 0
    }

    final cacheFile = File(
      '${_thumbDir().path}${Platform.pathSeparator}'
      '${_hash('$fullPath|$mtime|$width')}.jpg',
    );
    Uint8List? thumb;
    if (await cacheFile.exists()) {
      try {
        thumb = await cacheFile.readAsBytes();
      } catch (_) {
        thumb = null;
      }
    }

    if (thumb == null || thumb.isEmpty) {
      final frame = await VideoThumbnailService.thumbnailFor(fullPath);
      if (frame == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      thumb = await compute(_encodeThumbnail, _ThumbTask(frame.bytes, width));
      if (thumb == null) {
        response.statusCode = HttpStatus.unsupportedMediaType;
        await response.close();
        return;
      }
      try {
        await cacheFile.writeAsBytes(thumb, flush: false);
      } catch (_) {
        // 缓存写入失败不影响本次响应
      }
    }

    response.headers.contentType = ContentType('image', 'jpeg');
    response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=86400',
    );
    response.contentLength = thumb.length;
    response.add(thumb);
    await response.close();
  }

  /// 远程排除播放：仅把文件记入本机排除列表，不删除磁盘文件。
  ///
  /// 请求方式必须是 POST；未开启「允许远程排除播放」时拒绝，
  /// 且只能排除当前共享目录中真实列出的视频（id 经过目录内校验）。
  Future<void> _serveExclude(
    HttpRequest request,
    Uri uri,
    HttpResponse response,
  ) async {
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    if (!(_remoteExcludeEnabled?.call() ?? false)) {
      response.statusCode = HttpStatus.forbidden;
      response.write('Remote Exclude Disabled');
      await response.close();
      return;
    }

    final root = _folderById(uri.queryParameters['folder']);
    final fullPath = root == null
        ? null
        : _resolveWithin(root, uri.queryParameters['id'] ?? '');
    if (root == null || fullPath == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    // 已排除过则直接成功，保证请求重试是幂等的
    if (_isExcluded(fullPath)) {
      await _writeJson(response, {'ok': true});
      return;
    }

    // 只允许排除该共享目录中确实存在的视频
    final videos = await _videosForPath(root);
    final relative = _relativeTo(root, fullPath);
    final exists = videos.any(
      (item) => _relativeTo(root, item.path) == relative,
    );
    if (!exists) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    // 本机其他逻辑按原始路径比较，Windows 下需还原为反斜杠分隔
    final storedPath = Platform.isWindows
        ? fullPath.replaceAll('/', '\\')
        : fullPath;
    _onExcludedPath?.call(storedPath);
    // 排除后目录与排序缓存失效，后续列表立即反映结果
    _folderCache.remove(root);
    _sortCache.removeWhere((key, _) => key.startsWith('$root|'));
    await _writeJson(response, {'ok': true});
  }

  Future<void> _writeJson(HttpResponse response, Object data) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }

  /// 根据稳定标识查找共享目录
  String? _folderById(String? id) {
    if (id == null || id.isEmpty) return null;
    final paths = _folderPaths?.call() ?? const <String>[];
    for (final path in paths) {
      if (folderIdFor(path) == id) return path;
    }
    return null;
  }

  /// 为共享目录生成稳定标识。
  ///
  /// 不能直接使用列表下标：用户增删共享文件夹后位置会变化，
  /// 已持久化在其他设备上的选择会因此指向错误目录。
  static String folderIdFor(String path) {
    final normalized = path.replaceAll('\\', '/');
    return '${_hash('folder:$normalized')}${_hash('folder2:$normalized')}';
  }

  /// 判断某个绝对路径是否已被本机排除播放
  bool _isExcluded(String path) {
    final list = _excludedPaths?.call();
    if (list == null || list.isEmpty) return false;
    final normalized = path.replaceAll('\\', '/');
    for (final item in list) {
      if (item.replaceAll('\\', '/') == normalized) return true;
    }
    return false;
  }

  static String _folderName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  /// 把远端传入的相对路径解析到共享目录内，越界时返回 null
  static String? _resolveWithin(String root, String relative) {
    if (relative.isEmpty) return null;
    final normalizedRoot = root.replaceAll('\\', '/');
    final stack = <String>[];
    for (final part in relative.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (stack.isEmpty) return null;
        stack.removeLast();
      } else {
        stack.add(part);
      }
    }
    if (stack.isEmpty) return null;
    final joined = '$normalizedRoot/${stack.join('/')}';
    if (!joined.startsWith('$normalizedRoot/')) return null;
    // 统一还原为当前平台的分隔符：Windows 下 Shell 缩略图接口
    // （SHCreateItemFromParsingName）不接受正斜杠路径，而目录扫描与
    // 已排除列表保存的都是反斜杠路径，换回来还能保证缩略图缓存命中。
    return joined.replaceAll('/', Platform.pathSeparator);
  }

  /// 计算文件相对共享目录的路径，统一使用 '/' 分隔
  static String _relativeTo(String root, String path) {
    final normalizedRoot = root.replaceAll('\\', '/');
    final normalizedPath = path.replaceAll('\\', '/');
    if (normalizedPath == normalizedRoot) return '';
    if (normalizedPath.startsWith('$normalizedRoot/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    return normalizedPath.split('/').last;
  }

  static ContentType _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return ContentType('video', 'mp4');
      case 'mov':
        return ContentType('video', 'quicktime');
      case 'mkv':
        return ContentType('video', 'x-matroska');
      case 'webm':
        return ContentType('video', 'webm');
      case 'avi':
        return ContentType('video', 'x-msvideo');
      case 'wmv':
        return ContentType('video', 'x-ms-wmv');
      default:
        return ContentType('application', 'octet-stream');
    }
  }

  Directory _thumbDir() {
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}steam_flow_lan_thumbs',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// FNV-1a 哈希，用于生成稳定的缩略图缓存文件名与目录标识
  static String _hash(String input) {
    var hash = 0x811c9dc5;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
