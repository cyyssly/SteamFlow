/// 局域网共享播放的协议常量与路径。
///
/// 服务端只读：仅暴露共享目录中的视频元数据、首帧缩略图与原片；
/// 原片接口必须支持 HTTP Range，否则播放器无法拖动进度条。
class LanProtocol {
  /// 协议版本，收发双方不一致时忽略
  static const int version = 1;

  /// 默认 HTTP 数据端口（被占用时服务端会顺延）。
  ///
  /// 刻意避开 FrameFlow 使用的 45888/45889，避免两个应用在同一台设备上
  /// 同时运行时互相抢占端口；同时选在 49152 以下、IANA 未分配的冷门端口，
  /// 不与常见服务及系统临时端口范围冲突。
  static const int defaultHttpPort = 48321;

  /// UDP 发现端口
  static const int discoveryPort = 48322;

  /// 设备发现广播间隔
  static const Duration beaconInterval = Duration(seconds: 3);

  /// 超过该时间没有心跳即视为离线
  static const Duration deviceTimeout = Duration(seconds: 12);

  static const String infoPath = '/api/v1/info';
  static const String foldersPath = '/api/v1/folders';
  static const String videosPath = '/api/v1/videos';
  static const String videoPath = '/api/v1/video';
  static const String thumbPath = '/api/v1/thumb';

  /// 远程排除播放（仅记录排除，不删除文件）
  static const String excludePath = '/api/v1/exclude';

  static const String beaconType = 'beacon';
  static const String probeType = 'probe';
}
