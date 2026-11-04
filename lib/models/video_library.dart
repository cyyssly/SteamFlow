/// 一个独立的视频库：拥有自己的名称、本地文件夹与共享文件夹绑定。
///
/// 多个库之间互不关联，但同一个文件夹（本地或共享）允许同时归入多个库，
/// 便于做「合集」类的聚合库。当前激活库的本地文件夹通过
/// `SettingsProvider.lastFolderPaths` 暴露给全应用，因此既有代码无需感知库
/// 的存在。
class VideoLibrary {
  /// 稳定标识（创建后不变），用于跨会话识别
  final String id;

  /// 显示名称（可由用户重命名）
  String name;

  /// 该库包含的本地文件夹路径列表
  List<String> folderPaths;

  /// 该库绑定的共享文件夹键（与 `SharedFolderRef.key` 一致）
  List<String> sharedFolderKeys;

  /// 是否隐藏。隐藏库默认不出现在库列表中，仅在开启「显示隐藏媒体库」时
  /// 以半透明样式展示。
  bool hidden;

  VideoLibrary({
    required this.id,
    required this.name,
    required this.folderPaths,
    List<String>? sharedFolderKeys,
    this.hidden = false,
  }) : sharedFolderKeys = sharedFolderKeys ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'folderPaths': folderPaths,
    'sharedFolderKeys': sharedFolderKeys,
    'hidden': hidden,
  };

  /// 从持久化的 JSON 还原；结构不合法时返回 null
  static VideoLibrary? fromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final folderPaths = value['folderPaths'];
    final sharedFolderKeys = value['sharedFolderKeys'];
    if (id is! String || name is! String) return null;
    return VideoLibrary(
      id: id,
      name: name,
      folderPaths: folderPaths is List
          ? folderPaths.whereType<String>().toList()
          : [],
      sharedFolderKeys: sharedFolderKeys is List
          ? sharedFolderKeys.whereType<String>().toList()
          : [],
      hidden: value['hidden'] == true,
    );
  }
}
