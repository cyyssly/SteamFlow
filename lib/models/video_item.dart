class VideoItem {
  final String name;
  final String path;

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
    this.aspectRatio,
    this.modifiedTime,
    this.sizeBytes,
    this.width,
    this.height,
  });
}
