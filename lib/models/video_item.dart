class VideoItem {
  final String name;
  final String path;

  /// 视频宽高比（宽/高），用于瀑布流布局。未知时为 null。
  final double? aspectRatio;

  VideoItem({required this.name, required this.path, this.aspectRatio});
}
