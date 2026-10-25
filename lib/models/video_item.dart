/// 视频来源：本机文件或局域网共享
enum VideoSource { local, remote }

class VideoItem {
  final String name;
  final String path;

  /// 视频来源（本机文件 / 局域网共享）
  final VideoSource source;

  /// 远端原片地址（仅 remote 使用）
  final String? remoteUrl;

  /// 远端缩略图地址（仅 remote 使用）
  final String? thumbUrl;

  /// 远端主机 id（仅 remote 使用）
  final String? deviceId;

  /// 远端视频在该主机内的唯一标识（仅 remote 使用）
  final String? remoteId;

  /// 视频宽高比（宽/高），用于瀑布流布局。未知时为 null。
  final double? aspectRatio;

  /// 文件修改时间（瀑布流卡片「日期」用）。未知时为 null。
  final DateTime? modifiedTime;

  /// 文件大小（字节，瀑布流卡片「大小」用）。未知时为 null。
  final int? sizeBytes;

  /// 视频真实分辨率（瀑布流卡片「分辨率」用）。未知时为 null。
  ///
  /// 不能由缩略图尺寸推导：缩略图会被等比缩放到 512 以内，
  /// 只能反映宽高比，不能反映真实像素。
  final int? width;
  final int? height;

  VideoItem({
    required this.name,
    required this.path,
    this.source = VideoSource.local,
    this.remoteUrl,
    this.thumbUrl,
    this.deviceId,
    this.remoteId,
    this.aspectRatio,
    this.modifiedTime,
    this.sizeBytes,
    this.width,
    this.height,
  });

  bool get isRemote => source == VideoSource.remote;

  /// 列表去重与状态比较用的唯一键。
  ///
  /// 本机用路径；远端用「设备 + 文件夹 + 相对路径」，
  /// 避免不同共享目录中的同名文件互相覆盖。
  String get key => isRemote
      ? 'remote://${deviceId ?? ''}/${remoteId ?? ''}'
      : path;

  /// 交给播放器打开的地址：本机路径或远端 HTTP 地址。
  String get playbackUrl => isRemote ? (remoteUrl ?? '') : path;
}

