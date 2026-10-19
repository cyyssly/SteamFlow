/// 支持的视频容器格式（全项目唯一来源，扫描与统计都引用这里）。
///
/// 播放由 libmpv（FFmpeg）负责，能解更多容器；但**取首帧走各平台自身的解码路径**
/// （Windows 用 Shell 缩略图处理器、Android 用 MediaMetadataRetriever），
/// 那才是真正的限制项。这里收录「各平台较有把握取到首帧」的容器：
///
/// · mp4 / m4v / mov：Windows 有 MF MPEG-4 处理器，Android 原生支持；
/// · mkv / webm：Android 原生支持，Windows 依赖第三方 Shell 处理器（如 Icaros）；
/// · avi / wmv：mpv 均可播放；Windows 上 wmv 有系统处理器、avi 依赖第三方处理器，
///   Android 支持不一。
///
/// 个别文件取不到首帧时，瀑布流卡片会退回占位图，不影响播放。
const Set<String> supportedVideoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  'wmv',
};

/// 按扩展名判断路径是否为受支持的视频。
bool isSupportedVideoPath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex == -1) return false;
  final ext = path.toLowerCase().substring(dotIndex + 1);
  return supportedVideoExtensions.contains(ext);
}
