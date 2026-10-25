import 'package:steam_flow/models/video_item.dart';

/// 局域网中发现的设备
class LanDevice {
  final String id;
  final String name;
  final String host;
  final int port;

  /// 该设备共享的文件夹数量
  final int folderCount;

  /// 是否为用户手动输入的地址（手动设备不会因超时被移除）
  final bool manual;

  final DateTime lastSeen;

  const LanDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.folderCount,
    required this.lastSeen,
    this.manual = false,
  });

  String get baseUrl => 'http://$host:$port';

  String get address => '$host:$port';

  LanDevice copyWith({
    String? name,
    String? host,
    int? port,
    int? folderCount,
    bool? manual,
    DateTime? lastSeen,
  }) {
    return LanDevice(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      folderCount: folderCount ?? this.folderCount,
      manual: manual ?? this.manual,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// 远端设备允许本机执行的操作
class RemoteCapabilities {
  /// 是否允许远程排除播放
  final bool exclude;

  /// 是否允许远程复制视频
  final bool copy;

  const RemoteCapabilities({this.exclude = false, this.copy = false});

  static const RemoteCapabilities none = RemoteCapabilities();
}

/// 远端设备上的共享文件夹
class RemoteFolder {
  /// 服务端生成的稳定标识，与文件夹在列表中的位置无关
  final String id;
  final String name;
  final int videoCount;

  const RemoteFolder({
    required this.id,
    required this.name,
    required this.videoCount,
  });
}

/// 已添加的共享文件夹（作为播放源持久化在本机）
class SharedFolderRef {
  /// 共享源设备标识
  final String deviceId;

  /// 共享源设备名称（离线时用于展示）
  final String deviceName;

  /// 最近一次连接成功的地址，设备重新发现后会刷新
  final String host;
  final int port;

  /// 远端文件夹标识
  final String folderId;
  final String folderName;
  final int videoCount;

  const SharedFolderRef({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.folderId,
    required this.folderName,
    this.videoCount = 0,
  });

  /// 在本机列表中区分共享文件夹的唯一键
  String get key => '$deviceId/$folderId';

  String get address => '$host:$port';

  SharedFolderRef copyWith({
    String? deviceName,
    String? host,
    int? port,
    String? folderId,
    String? folderName,
    int? videoCount,
  }) {
    return SharedFolderRef(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      host: host ?? this.host,
      port: port ?? this.port,
      folderId: folderId ?? this.folderId,
      folderName: folderName ?? this.folderName,
      videoCount: videoCount ?? this.videoCount,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'host': host,
      'port': port,
      'folderId': folderId,
      'folderName': folderName,
      'videoCount': videoCount,
    };
  }

  static SharedFolderRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    final folderId = json['folderId'];
    final host = json['host'];
    final port = json['port'];
    if (deviceId is! String || deviceId.isEmpty) return null;
    if (folderId is! String || folderId.isEmpty) return null;
    if (host is! String || host.isEmpty) return null;
    if (port is! int) return null;
    final name = json['deviceName'];
    final folderName = json['folderName'];
    return SharedFolderRef(
      deviceId: deviceId,
      deviceName: name is String && name.isNotEmpty ? name : host,
      host: host,
      port: port,
      folderId: folderId,
      folderName: folderName is String && folderName.isNotEmpty
          ? folderName
          : folderId,
      videoCount: json['videoCount'] is int ? json['videoCount'] as int : 0,
    );
  }
}

/// 远端视频分页结果
class RemoteVideoPage {
  final List<VideoItem> items;
  final int total;
  final int nextOffset;

  const RemoteVideoPage({
    required this.items,
    required this.total,
    required this.nextOffset,
  });
}
