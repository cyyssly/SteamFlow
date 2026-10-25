import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/services/lan_protocol.dart';

/// 远端文件下载结果
enum DownloadStatus { success, cancelled, failed }

/// 下载过程中主动取消时抛出的内部信号
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// 分片文件的元数据，用于判断续传是否仍然有效
class _PartMeta {
  final String url;
  final String? etag;
  final int total;

  const _PartMeta({required this.url, this.etag, this.total = 0});

  Map<String, Object?> toJson() => {
    'version': 1,
    'url': url,
    if (etag != null) 'etag': etag,
    'total': total,
  };

  static _PartMeta? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['version'] != 1) return null;
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    final etag = json['etag'];
    final total = json['total'];
    return _PartMeta(
      url: url,
      etag: etag is String && etag.isNotEmpty ? etag : null,
      total: total is int && total >= 0 ? total : 0,
    );
  }
}

/// 局域网客户端：负责向远端主机发起只读的 HTTP 请求。
class LanClientService {
  static final LanClientService instance = LanClientService._();

  LanClientService._();

  static const Duration _timeout = Duration(seconds: 4);

  /// 文件列表类接口的响应时间上限。
  ///
  /// 共享目录视频较多时，服务端需要遍历目录并为缺失尺寸的视频取帧，
  /// 首次请求可能明显超过心跳接口的 4 秒，不能沿用同一个超时时间。
  static const Duration _dataTimeout = Duration(seconds: 30);

  HttpClient? _client;

  HttpClient get _http =>
      _client ??= HttpClient()..connectionTimeout = _timeout;

  /// 读取远端设备信息，设备不可达时返回 null
  Future<Map<String, dynamic>?> fetchInfo(LanDevice device) async {
    final uri = Uri.parse('${device.baseUrl}${LanProtocol.infoPath}');
    return _getJson(uri);
  }

  /// 下载二进制资源（如缩略图），失败返回 null
  Future<Uint8List?> fetchBytes(String url) async {
    try {
      final request = await _http.getUrl(Uri.parse(url)).timeout(_dataTimeout);
      final response = await request.close().timeout(_dataTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add).timeout(_dataTimeout);
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  /// 读取远端共享的文件夹列表
  Future<List<RemoteFolder>?> fetchFolders(LanDevice device) async {
    final uri = Uri.parse('${device.baseUrl}${LanProtocol.foldersPath}');
    final data = await _getJson(uri, timeout: _dataTimeout);
    final raw = data?['folders'];
    if (raw is! List) return null;

    final folders = <RemoteFolder>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      final name = (entry['name'] as String?)?.trim();
      folders.add(
        RemoteFolder(
          id: id,
          name: name != null && name.isNotEmpty ? name : id,
          videoCount: entry['count'] is int ? entry['count'] as int : 0,
        ),
      );
    }
    return folders;
  }

  /// 读取远端文件夹中的一页视频。
  ///
  /// [sort] 为 `name` / `time` / `size` / `random`，为空时使用服务端默认顺序；
  /// [order] 为 `asc` / `desc`；随机排序需同时传入同一次浏览固定的 [seed]，
  /// 否则各页顺序会不一致。
  Future<RemoteVideoPage?> fetchVideos(
    LanDevice device, {
    required String folderId,
    int offset = 0,
    int limit = 60,
    String? sort,
    String? order,
    String? seed,
  }) async {
    final uri = _api(device, LanProtocol.videosPath, {
      'folder': folderId,
      'offset': '$offset',
      'limit': '$limit',
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
      if (seed != null && seed.isNotEmpty) 'seed': seed,
    });
    final data = await _getJson(uri, timeout: _dataTimeout);
    final raw = data?['items'];
    if (raw is! List) return null;

    final items = <VideoItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      final aspect = entry['aspect'];
      final mtime = entry['mtime'];
      final width = entry['width'];
      final height = entry['height'];
      items.add(
        VideoItem(
          name: (entry['name'] as String?)?.trim().isNotEmpty == true
              ? entry['name'] as String
              : id.split('/').last,
          path: '',
          source: VideoSource.remote,
          aspectRatio: aspect is num ? aspect.toDouble() : null,
          remoteUrl: videoUrl(device, folderId, id),
          thumbUrl: thumbUrl(device, folderId, id),
          deviceId: device.id,
          // 同一设备的不同共享目录可能包含同名相对路径，
          // 带上文件夹标识才能保证播放列表去重正确
          remoteId: '$folderId/$id',
          modifiedTime: mtime is int
              ? DateTime.fromMillisecondsSinceEpoch(mtime)
              : null,
          sizeBytes: entry['size'] is int ? entry['size'] as int : null,
          width: width is int ? width : null,
          height: height is int ? height : null,
        ),
      );
    }

    final total = data?['total'] is int ? data!['total'] as int : items.length;
    return RemoteVideoPage(
      items: items,
      total: total,
      nextOffset: offset + items.length,
    );
  }

  /// 取回远端文件夹的全部视频元数据，失败时返回 null。
  ///
  /// 排序参数交给服务端，保证跨页顺序一致（随机排序尤其需要固定 [seed]）。
  Future<List<VideoItem>?> fetchAllVideos(
    LanDevice device, {
    required String folderId,
    int pageSize = 500,
    String? sort,
    String? order,
    String? seed,
  }) async {
    final all = <VideoItem>[];
    var offset = 0;
    while (true) {
      final page = await fetchVideos(
        device,
        folderId: folderId,
        offset: offset,
        limit: pageSize,
        sort: sort,
        order: order,
        seed: seed,
      );
      if (page == null) return null;
      all.addAll(page.items);
      if (page.items.isEmpty || all.length >= page.total) break;
      if (page.nextOffset <= offset) break;
      offset = page.nextOffset;
    }
    return all;
  }

  /// 请求远端设备把某个视频加入排除列表（仅排除播放，不删除文件）
  ///
  /// 远端未开启「允许远程排除播放」或校验失败时返回 false。
  Future<bool> excludeVideo(
    LanDevice device, {
    required String folderId,
    required String id,
  }) async {
    final uri = _api(device, LanProtocol.excludePath, {
      'folder': folderId,
      'id': id,
    });
    try {
      final request = await _http.postUrl(uri).timeout(_dataTimeout);
      request.contentLength = 0;
      final response = await request.close().timeout(_dataTimeout);
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  /// 把远端原片下载到本地文件，支持进度回调、主动取消与断点续传。
  ///
  /// 视频体积大，必须流式写入磁盘，不能整文件读入内存；
  /// 下载不设总超时（只受连接超时限制）。
  ///
  /// [target] 已存在且带有有效 `.meta` 分片元数据时会带上 `Range` + `If-Range`
  /// 请求头尝试续传：
  ///  * 返回 206：从已有长度处追加；
  ///  * 返回 200：远端文件已变化（或服务端不支持 Range），整文件覆盖重写；
  ///  * 返回 416：分片已完整则直接成功，否则清空重下。
  ///
  /// 分片缺少元数据、元数据损坏或远端文件大小变化时，分片一律视为不可信并重下，
  /// 避免把新旧两个版本的文件拼在一起。
  ///
  /// [onProgress] 的参数为「已接收字节数 / 总字节数」，总长度未知时为 0。
  Future<DownloadStatus> downloadVideo(
    String url,
    File target, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final metaFile = File('${target.path}.meta');
    var existing = 0;
    try {
      if (await target.exists()) existing = await target.length();
    } catch (_) {
      existing = 0;
    }

    var meta = await _readPartMeta(metaFile);
    // 无可靠元数据的分片不可信（旧版本或元数据损坏），直接丢弃重下
    if (existing > 0 &&
        (meta == null ||
            meta.url != url ||
            meta.etag == null ||
            meta.etag!.isEmpty)) {
      existing = 0;
      meta = null;
      await _deleteQuietly(target);
      await _deleteQuietly(metaFile);
    }
    if (isCancelled?.call() ?? false) return DownloadStatus.cancelled;

    try {
      final request = await _http.getUrl(Uri.parse(url));
      if (existing > 0 && meta?.etag != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        request.headers.set(HttpHeaders.ifRangeHeader, meta!.etag!);
      }
      final response = await request.close();
      final responseEtag = response.headers.value(HttpHeaders.etagHeader);

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existing > 0) {
        final total = _totalFromContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        await response.drain<void>();
        if (total != null && total == existing) {
          // 上次已下载完整，只是还没转存到目标目录
          onProgress?.call(existing, total);
          return DownloadStatus.success;
        }
        // 缓存的分片已失效（远端文件变了），从头重新下载
        await _deleteQuietly(target);
        await _deleteQuietly(metaFile);
        return downloadVideo(
          url,
          target,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }

      final partial = response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok && !partial) {
        await response.drain<void>();
        return DownloadStatus.failed;
      }

      // 206 从已有长度处续写；200 表示服务端没走 Range，需要整文件覆盖
      final start = partial ? existing : 0;
      final responseTotal = partial
          ? _totalFromContentRange(
              response.headers.value(HttpHeaders.contentRangeHeader),
            )
          : (response.contentLength > 0 ? response.contentLength : null);

      // 远端文件大小已变化：旧分片不可续写，清空后重新下载
      if (partial &&
          meta != null &&
          meta.total > 0 &&
          responseTotal != null &&
          responseTotal != meta.total) {
        await response.drain<void>();
        await _deleteQuietly(target);
        await _deleteQuietly(metaFile);
        return downloadVideo(
          url,
          target,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }

      final total =
          responseTotal ??
          (start + (response.contentLength > 0 ? response.contentLength : 0));
      // 先落盘元数据：即使下载中途崩溃，下次也能判断分片属于哪个版本
      await _writePartMeta(
        metaFile,
        _PartMeta(
          url: url,
          etag: responseEtag ?? meta?.etag,
          total: total > 0 ? total : (meta?.total ?? 0),
        ),
      );

      final sink = target.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
      var received = start;
      onProgress?.call(received, total);
      try {
        await sink.addStream(
          response.map((chunk) {
            if (isCancelled?.call() ?? false) {
              throw const _DownloadCancelled();
            }
            received += chunk.length;
            onProgress?.call(received, total);
            return chunk;
          }),
        );
        await sink.flush();
        await sink.close();
        // 总长度已知时必须完全一致，否则说明连接中断或分片损坏
        if (total > 0 && received != total) {
          return DownloadStatus.failed;
        }
        return DownloadStatus.success;
      } on _DownloadCancelled {
        try {
          await sink.close();
        } catch (_) {
          // 关闭失败不影响「已取消」这一结果
        }
        return DownloadStatus.cancelled;
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {
          // 关闭失败仍按下载失败处理
        }
        return DownloadStatus.failed;
      }
    } catch (_) {
      return DownloadStatus.failed;
    }
  }

  static Future<_PartMeta?> _readPartMeta(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return _PartMeta.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writePartMeta(File file, _PartMeta meta) async {
    try {
      // 先写临时文件再改名，避免中断时留下半个 JSON
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(meta.toJson()), flush: true);
      await temp.rename(file.path);
    } catch (_) {
      // 元数据写失败时下次会按无元数据重下，不影响本次下载
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败时由后续写入覆盖
    }
  }

  /// 从 `Content-Range: bytes 0-99/12345` 中解析出总长度
  static int? _totalFromContentRange(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0 || slash == value.length - 1) return null;
    return int.tryParse(value.substring(slash + 1));
  }

  /// 远端原片地址
  String videoUrl(LanDevice device, String folderId, String id) {
    return _api(device, LanProtocol.videoPath, {
      'folder': folderId,
      'id': id,
    }).toString();
  }

  /// 远端缩略图地址
  String thumbUrl(
    LanDevice device,
    String folderId,
    String id, {
    int width = 512,
  }) {
    return _api(device, LanProtocol.thumbPath, {
      'folder': folderId,
      'id': id,
      'w': '$width',
    }).toString();
  }

  Uri _api(LanDevice device, String path, Map<String, String> query) {
    return Uri.parse('${device.baseUrl}$path').replace(queryParameters: query);
  }

  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    Duration timeout = _timeout,
  }) async {
    try {
      final request = await _http.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
