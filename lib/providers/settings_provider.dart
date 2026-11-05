import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_library.dart';

/// 播放顺序
///
/// 新增项必须追加在末尾：该枚举按下标持久化到 SharedPreferences，
/// 插在中间会让老用户已保存的下标含义错位。
enum PlayOrder {
  sequential,
  random,
  newestFirst,
  oldestFirst,
  newPreferred,
  reverseSequential, // 逆序播放（按文件名降序）
  sizeLargest, // 由大到小（按文件大小降序）
  sizeSmallest, // 由小到大（按文件大小升序）
}

enum VideoFitMode { contain, cover, original }

enum DeleteAction {
  exclude, // 排除播放
  delete, // 实际删除
}

/// 左右方向键的行为。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum ArrowKeyAction {
  seek, // 前进/后退（每次跳进度条的 5%）
  switchVideo, // 切换视频
}

/// 手机端瀑布流卡片的短按行为。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum MobileTapAction {
  play, // 短按直接播放，长按选中
  select, // 短按选中，长按或再次短按播放
}

/// 未播放完毕的视频下次进入时从何处开始播放。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum ResumePlayback {
  resume, // 接续上次进度
  restart, // 从头播放
}

enum VideoOrientation {
  landscape, // 横屏
  portrait, // 竖屏
  followSystem, // 跟随系统
  followVideo, // 跟随视频
}

/// 瀑布流卡片下方展示的文件信息（单选）。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum FileListInfo {
  none, // 不显示
  name, // 文件名
  nameDateSize, // 文件名 + 日期 + 大小
}

/// 视频浏览格式（瀑布流或固定画幅）。
///
/// 按下标持久化到 SharedPreferences，新增项请追加在末尾。
enum BrowseLayout {
  masonry, // 瀑布流（按视频原始比例）
  square, // 正方形
  landscape4x3, // 横屏 4:3
  landscape16x9, // 横屏 16:9
  portrait3x4, // 竖屏 3:4
  portrait9x16, // 竖屏 9:16
}

extension BrowseLayoutAspect on BrowseLayout {
  /// 固定画幅的宽高比；瀑布流返回 null，表示沿用视频自身比例
  double? get aspectRatio => switch (this) {
    BrowseLayout.masonry => null,
    BrowseLayout.square => 1.0,
    BrowseLayout.landscape4x3 => 4 / 3,
    BrowseLayout.landscape16x9 => 16 / 9,
    BrowseLayout.portrait3x4 => 3 / 4,
    BrowseLayout.portrait9x16 => 9 / 16,
  };
}

class SettingsProvider extends ChangeNotifier {
  /// 字幕字号可调范围（libmpv 的 sub-font-size 默认值为 55）
  static const int subtitleFontSizeMin = 20;
  static const int subtitleFontSizeMax = 120;
  static const int subtitleFontSizeDefault = 55;

  // 播放基础设置
  PlayOrder _playOrder = PlayOrder.newPreferred;
  ResumePlayback _resumePlayback = ResumePlayback.resume;
  bool _loopPlay = false;
  bool _autoPlay = true;

  // 视频显示设置
  VideoFitMode _videoFitMode = VideoFitMode.contain;
  VideoOrientation _videoOrientation = VideoOrientation.followSystem;

  // 字幕样式（仅作用于文本字幕，通过 libmpv 属性实时生效）
  String _subtitleFontFamily = 'sans-serif';
  int _subtitleFontSize = subtitleFontSizeDefault;

  // 窗口/全屏控制
  bool _startFullscreen = true;
  bool _hideToolbar = true;
  int _controlsHideDelay = 3;
  bool _keepControlsOnPause = false;

  // 文件与目录相关
  bool _recursiveScan = true;
  FileListInfo _fileListInfo = FileListInfo.none;
  BrowseLayout _browseLayout = BrowseLayout.masonry;

  /// 本地文件夹的浏览格式（路径 → 格式 id），未记录时跟随设置页默认值
  Map<String, String> _localBrowseLayouts = {};

  /// 共享文件夹的浏览格式（共享文件夹 key → 格式 id）
  Map<String, String> _sharedBrowseLayouts = {};

  String? _lastFolderPath;
  List<String> _lastFolderPaths = [];

  /// 所有视频库（互不关联的文件夹集合）
  List<VideoLibrary> _libraries = [];

  /// 当前激活的库 id
  String _activeLibraryId = '';

  /// 库列表是否显示已隐藏的库（开启时半透明展示，关闭时完全隐藏）
  bool _showHiddenLibraries = false;

  // 视频底部信息条是否显示（自动隐藏跟随「工具栏」设置统一控制）
  bool _showVideoInfo = false;

  // 快捷键与控制
  bool _wheelSwitchVideo = true;

  /// 左右方向键的默认行为（默认前进/后退）
  ArrowKeyAction _arrowKeyAction = ArrowKeyAction.seek;

  /// 手机端短按卡片的行为（默认直接播放）
  MobileTapAction _mobileTapAction = MobileTapAction.play;

  /// Windows 端是否在支持的视频格式上注册「用 SteamFlow 播放」右键菜单
  bool _addToContextMenu = false;

  // 删除行为设置
  DeleteAction _deleteAction = DeleteAction.exclude;
  List<String> _excludedPaths = [];

  /// 本地文件夹的瀑布流排序方式（路径 → 排序 id）
  Map<String, String> _localSortModes = {};

  /// 共享文件夹的瀑布流排序方式（共享文件夹 key → 排序 id）
  Map<String, String> _sharedSortModes = {};

  /// 上次复制文件时使用的目标目录（Android 为 SAF URI，桌面为本地路径）
  String? _lastCopyDestination;

  // 语言设置（0=跟随系统, 1=简体中文, 2=English, 3=繁體中文）
  int _languageIndex = 0;

  // 内网共享
  bool _lanShareEnabled = false;
  bool _allowRemoteExclude = false;
  bool _allowRemoteCopy = false;
  bool _closeToTray = false;
  Map<String, bool> _lanFolderSharing = {};

  /// 已添加的共享文件夹（来自其他设备，作为播放源持久化在本机）
  List<SharedFolderRef> _sharedFolders = [];

  /// 本机设备标识与名称（用于设备发现与去重）
  String _deviceId = '';
  String _deviceName = _defaultDeviceName();

  // Getters

  /// 当前激活库排除播放的视频路径；无库时回退到全局记录（迁移期兼容）。
  ///
  /// 排除是按库生效的：在 A 库排除的视频，切到 B 库后仍会正常播放。
  List<String> get excludedPaths => List.unmodifiable(_excludedList);

  /// 读取某个本地文件夹上次使用的排序方式；未记录时返回 null（跟随设置页）
  String? localSortFor(String folderPath) => _localSortModes[folderPath];

  /// 读取某个共享文件夹上次使用的排序方式；未记录时返回 null（跟随设置页）
  String? sharedSortFor(String folderKey) => _sharedSortModes[folderKey];

  /// 读取某个本地文件夹上次使用的浏览格式；未记录时返回 null（跟随设置页）
  String? localBrowseLayoutFor(String folderPath) =>
      _localBrowseLayouts[folderPath];

  /// 读取某个共享文件夹上次使用的浏览格式；未记录时返回 null（跟随设置页）
  String? sharedBrowseLayoutFor(String folderKey) =>
      _sharedBrowseLayouts[folderKey];

  /// 上次复制文件的目标目录
  String? get lastCopyDestination => _lastCopyDestination;

  PlayOrder get playOrder => _playOrder;
  ResumePlayback get resumePlayback => _resumePlayback;
  bool get loopPlay => _loopPlay;
  bool get autoPlay => _autoPlay;
  VideoFitMode get videoFitMode => _videoFitMode;
  VideoOrientation get videoOrientation => _videoOrientation;
  String get subtitleFontFamily => _subtitleFontFamily;
  int get subtitleFontSize => _subtitleFontSize;
  bool get startFullscreen => _startFullscreen;
  bool get hideToolbar => _hideToolbar;
  int get controlsHideDelay => _controlsHideDelay;
  bool get keepControlsOnPause => _keepControlsOnPause;
  bool get recursiveScan => _recursiveScan;
  FileListInfo get fileListInfo => _fileListInfo;
  BrowseLayout get browseLayout => _browseLayout;

  String? get lastFolderPath => _lastFolderPath;

  /// 当前激活库的文件夹列表；无库时回退到 [_lastFolderPaths]（迁移期兼容）。
  ///
  /// 现有所有代码都通过它读取「当前管理的文件夹」，因此引入多库后无需改动。
  List<String> get lastFolderPaths {
    final lib = activeLibrary;
    return lib != null ? lib.folderPaths : _lastFolderPaths;
  }

  /// 全部库（只读视图）
  List<VideoLibrary> get libraries => List.unmodifiable(_libraries);

  String get activeLibraryId => _activeLibraryId;

  /// 库列表是否显示已隐藏的库
  bool get showHiddenLibraries => _showHiddenLibraries;

  /// 当前激活的库；无库时返回 null
  VideoLibrary? get activeLibrary {
    for (final lib in _libraries) {
      if (lib.id == _activeLibraryId) return lib;
    }
    return _libraries.isNotEmpty ? _libraries.first : null;
  }

  /// 排除列表的实际存储位置：优先当前库，无库时用全局记录（迁移期兼容）
  List<String> get _excludedList {
    final lib = activeLibrary;
    return lib != null ? lib.excludedPaths : _excludedPaths;
  }

  bool get showVideoInfo => _showVideoInfo;
  bool get wheelSwitchVideo => _wheelSwitchVideo;
  ArrowKeyAction get arrowKeyAction => _arrowKeyAction;
  MobileTapAction get mobileTapAction => _mobileTapAction;
  bool get addToContextMenu => _addToContextMenu;
  DeleteAction get deleteAction => _deleteAction;
  int get languageIndex => _languageIndex;

  bool get lanShareEnabled => _lanShareEnabled;

  /// 是否允许其他设备把共享视频加入本机排除列表
  bool get allowRemoteExclude => _allowRemoteExclude;

  /// 是否允许其他设备把共享视频复制到它自己的设备
  bool get allowRemoteCopy => _allowRemoteCopy;

  /// 桌面端关闭窗口时是否收起到系统托盘（保持共享服务运行）
  bool get closeToTray => _closeToTray;

  Map<String, bool> get lanFolderSharing => Map.unmodifiable(_lanFolderSharing);

  /// 未显式设置过的本地文件夹默认参与共享
  bool isLocalFolderShared(String path) => _lanFolderSharing[path] ?? true;

  /// 所有共享源的全局登记表（供在线探测、封面缓存等底层逻辑使用）
  List<SharedFolderRef> get sharedFolders => List.unmodifiable(_sharedFolders);

  /// 当前激活库绑定的共享文件夹（按全局登记顺序）
  ///
  /// 无库时返回全部（迁移期兼容）。
  List<SharedFolderRef> get activeLibrarySharedFolders {
    final lib = activeLibrary;
    if (lib == null) return List.unmodifiable(_sharedFolders);
    final keys = lib.sharedFolderKeys.toSet();
    return List.unmodifiable([
      for (final ref in _sharedFolders)
        if (keys.contains(ref.key)) ref,
    ]);
  }

  /// 某个共享源是否已绑定到当前激活库
  bool isSharedFolderInActiveLibrary(String key) {
    final lib = activeLibrary;
    if (lib == null) return _sharedFolders.any((ref) => ref.key == key);
    return lib.sharedFolderKeys.contains(key);
  }

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;

  // Setters
  void setPlayOrder(PlayOrder value) {
    _playOrder = value;
    notifyListeners();
    _saveSettings();
  }

  void setResumePlayback(ResumePlayback value) {
    if (_resumePlayback == value) return;
    _resumePlayback = value;
    notifyListeners();
    _saveSettings();
  }

  void setLoopPlay(bool value) {
    _loopPlay = value;
    notifyListeners();
    _saveSettings();
  }

  void setAutoPlay(bool value) {
    _autoPlay = value;
    notifyListeners();
    _saveSettings();
  }

  void setVideoFitMode(VideoFitMode value) {
    _videoFitMode = value;
    notifyListeners();
    _saveSettings();
  }

  void setVideoOrientation(VideoOrientation value) {
    _videoOrientation = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置字幕字体；空串表示使用系统默认字体（sans-serif）
  void setSubtitleFontFamily(String value) {
    final font = value.trim().isEmpty ? 'sans-serif' : value.trim();
    if (_subtitleFontFamily == font) return;
    _subtitleFontFamily = font;
    notifyListeners();
    _saveSettings();
  }

  /// 设置字幕字号（自动夹紧到可调范围）
  void setSubtitleFontSize(int value) {
    final size = value.clamp(subtitleFontSizeMin, subtitleFontSizeMax);
    if (_subtitleFontSize == size) return;
    _subtitleFontSize = size;
    notifyListeners();
    _saveSettings();
  }

  void setStartFullscreen(bool value) {
    _startFullscreen = value;
    notifyListeners();
    _saveSettings();
  }

  void setHideToolbar(bool value) {
    _hideToolbar = value;
    notifyListeners();
    _saveSettings();
  }

  void setControlsHideDelay(int value) {
    _controlsHideDelay = value;
    notifyListeners();
    _saveSettings();
  }

  void setKeepControlsOnPause(bool value) {
    _keepControlsOnPause = value;
    notifyListeners();
    _saveSettings();
  }

  void setRecursiveScan(bool value) {
    _recursiveScan = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置瀑布流卡片下方展示的文件信息（单选）。
  void setFileListInfo(FileListInfo value) {
    _fileListInfo = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置默认的浏览格式（单个文件夹未单独设置时使用）
  void setBrowseLayout(BrowseLayout value) {
    if (_browseLayout == value) return;
    _browseLayout = value;
    notifyListeners();
    _saveSettings();
  }

  void setLastFolderPath(String? value) {
    _lastFolderPath = value;
    notifyListeners();
    _saveSettings();
  }

  void setLastFolderPaths(List<String> value) {
    final copy = List<String>.of(value);
    _lastFolderPaths = copy;
    // 还没有库时自动建立默认库，保证新添加的文件夹有库可归属
    _ensureActiveLibrary().folderPaths = copy;
    notifyListeners();
    _saveSettings();
  }

  void setShowVideoInfo(bool value) {
    _showVideoInfo = value;
    notifyListeners();
    _saveSettings();
  }

  void setWheelSwitchVideo(bool value) {
    _wheelSwitchVideo = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置左右方向键的行为
  void setArrowKeyAction(ArrowKeyAction value) {
    if (_arrowKeyAction == value) return;
    _arrowKeyAction = value;
    notifyListeners();
    _saveSettings();
  }

  /// 设置手机端短按卡片的行为
  void setMobileTapAction(MobileTapAction value) {
    if (_mobileTapAction == value) return;
    _mobileTapAction = value;
    notifyListeners();
    _saveSettings();
  }

  /// 记录右键菜单集成是否已启用（实际注册由设置页调用系统服务完成）
  void setAddToContextMenu(bool value) {
    if (_addToContextMenu == value) return;
    _addToContextMenu = value;
    notifyListeners();
    _saveSettings();
  }

  void setDeleteAction(DeleteAction value) {
    _deleteAction = value;
    notifyListeners();
    _saveSettings();
  }

  void setLanguageIndex(int value) {
    _languageIndex = value;
    notifyListeners();
    _saveSettings();
  }

  void addExcludedPath(String path) {
    // 还没有库时自动建立默认库，保证排除记录有库可归属
    final list = _ensureActiveLibrary().excludedPaths;
    if (!list.contains(path)) {
      list.add(path);
      notifyListeners();
      _saveSettings();
    }
  }

  void removeExcludedPath(String path) {
    final list = _excludedList;
    final before = list.length;
    // 历史数据里可能存在重复路径，这里一次性全部移除
    list.removeWhere((item) => item == path);
    if (list.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  /// 批量移除已排除路径（恢复某个文件夹分组时使用）
  void removeExcludedPaths(Iterable<String> paths) {
    final targets = paths.toSet();
    if (targets.isEmpty) return;
    final list = _excludedList;
    final before = list.length;
    list.removeWhere(targets.contains);
    if (list.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    final list = _excludedList;
    if (list.isEmpty) return;
    list.clear();
    notifyListeners();
    _saveSettings();
  }

  /// 记住某个本地文件夹的瀑布流排序方式
  void setLocalSort(String folderPath, String sortId) {
    if (_localSortModes[folderPath] == sortId) return;
    _localSortModes[folderPath] = sortId;
    _saveSettings();
  }

  /// 记住某个共享文件夹的瀑布流排序方式
  void setSharedSort(String folderKey, String sortId) {
    if (_sharedSortModes[folderKey] == sortId) return;
    _sharedSortModes[folderKey] = sortId;
    _saveSettings();
  }

  /// 记住某个本地文件夹的浏览格式
  void setLocalBrowseLayout(String folderPath, BrowseLayout layout) {
    if (_localBrowseLayouts[folderPath] == layout.name) return;
    _localBrowseLayouts[folderPath] = layout.name;
    _saveSettings();
  }

  /// 记住某个共享文件夹的浏览格式
  void setSharedBrowseLayout(String folderKey, BrowseLayout layout) {
    if (_sharedBrowseLayouts[folderKey] == layout.name) return;
    _sharedBrowseLayouts[folderKey] = layout.name;
    _saveSettings();
  }

  /// 记住上次复制文件的目标目录
  void setLastCopyDestination(String destination) {
    if (_lastCopyDestination == destination) return;
    _lastCopyDestination = destination;
    _saveSettings();
  }

  // ── 内网共享 ──

  void setLanShareEnabled(bool value) {
    if (_lanShareEnabled == value) return;
    _lanShareEnabled = value;
    notifyListeners();
    _saveSettings();
  }

  void setAllowRemoteExclude(bool value) {
    if (_allowRemoteExclude == value) return;
    _allowRemoteExclude = value;
    notifyListeners();
    _saveSettings();
  }

  void setAllowRemoteCopy(bool value) {
    if (_allowRemoteCopy == value) return;
    _allowRemoteCopy = value;
    notifyListeners();
    _saveSettings();
  }

  void setCloseToTray(bool value) {
    if (_closeToTray == value) return;
    _closeToTray = value;
    notifyListeners();
    _saveSettings();
  }

  void setLanFolderShared(String path, bool value) {
    if ((_lanFolderSharing[path] ?? true) == value) return;
    _lanFolderSharing[path] = value;
    notifyListeners();
    _saveSettings();
  }

  void setAllLanFoldersShared(List<String> paths, bool value) {
    var changed = false;
    for (final path in paths) {
      if ((_lanFolderSharing[path] ?? true) != value) {
        _lanFolderSharing[path] = value;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    _saveSettings();
  }

  /// 添加共享文件夹，并绑定到当前激活的库。
  ///
  /// 同一个共享源可以被多个库分别绑定：再次添加时只更新全局登记信息，
  /// 并确保当前库已包含该绑定。
  void addSharedFolder(SharedFolderRef ref) {
    _sharedFolders.removeWhere((item) => item.key == ref.key);
    _sharedFolders.add(ref);
    // 还没有库时自动建立默认库，保证共享源有库可绑定
    final lib = _ensureActiveLibrary();
    if (!lib.sharedFolderKeys.contains(ref.key)) {
      lib.sharedFolderKeys.add(ref.key);
    }
    notifyListeners();
    _saveSettings();
  }

  void updateSharedFolder(SharedFolderRef ref) {
    final index = _sharedFolders.indexWhere((item) => item.key == ref.key);
    if (index < 0) return;
    final current = _sharedFolders[index];
    if (current.deviceName == ref.deviceName &&
        current.host == ref.host &&
        current.port == ref.port &&
        current.folderName == ref.folderName &&
        current.videoCount == ref.videoCount) {
      return;
    }
    _sharedFolders[index] = ref;
    notifyListeners();
    _saveSettings();
  }

  /// 把共享文件夹从当前激活库解绑。
  ///
  /// 若已没有任何库绑定该共享源，则连同全局登记一起清除。
  void removeSharedFolderFromActiveLibrary(String key) {
    final lib = activeLibrary;
    if (lib == null) return;
    final before = lib.sharedFolderKeys.length;
    lib.sharedFolderKeys.removeWhere((item) => item == key);
    if (lib.sharedFolderKeys.length == before) return;
    _pruneUnusedSharedFolders();
    notifyListeners();
    _saveSettings();
  }

  /// 清除没有被任何库引用的共享源登记，避免继续探测与缓存无用源
  void _pruneUnusedSharedFolders() {
    final used = <String>{
      for (final lib in _libraries) ...lib.sharedFolderKeys,
    };
    _sharedFolders.removeWhere((ref) => !used.contains(ref.key));
  }

  // ── 多媒体库 ──

  /// 返回当前激活库；一个库都没有时自动创建「默认媒体库」。
  ///
  /// 新用户可能先加文件夹/共享源再建库，这里保证数据总有归属。
  VideoLibrary _ensureActiveLibrary() {
    final existing = activeLibrary;
    if (existing != null) return existing;
    final lib = VideoLibrary(
      id: 'lib_default',
      name: _defaultLibraryName(),
      folderPaths: [],
    );
    _libraries.add(lib);
    _activeLibraryId = lib.id;
    return lib;
  }

  /// 设置库列表是否显示隐藏库（关闭时列表中完全不出现）。
  ///
  /// 关闭开关时，若当前激活库是隐藏库，会自动切换到第一个未隐藏的库并返回
  /// true，调用方需要同步 [SlideProvider] 的文件夹。没有未隐藏库时保持原状
  /// 并返回 false（此时库列表里一个库也不显示）。
  bool setShowHiddenLibraries(bool value) {
    if (_showHiddenLibraries == value) return false;
    _showHiddenLibraries = value;

    var activeChanged = false;
    if (!value) {
      final active = activeLibrary;
      if (active != null && active.hidden) {
        for (final lib in _libraries) {
          if (!lib.hidden) {
            _activeLibraryId = lib.id;
            _lastFolderPaths = lib.folderPaths;
            activeChanged = true;
            break;
          }
        }
      }
    }

    notifyListeners();
    _saveSettings();
    return activeChanged;
  }

  /// 新建一个空库并切换到它（名称自动去重，避免两个同名库难以区分）
  void addLibrary(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    var unique = trimmed;
    var suffix = 2;
    while (_libraries.any((lib) => lib.name == unique)) {
      unique = '$trimmed $suffix';
      suffix++;
    }

    final lib = VideoLibrary(
      id: 'lib_${DateTime.now().microsecondsSinceEpoch}',
      name: unique,
      folderPaths: [],
    );
    _libraries.add(lib);
    _activeLibraryId = lib.id;
    _lastFolderPaths = [];
    notifyListeners();
    _saveSettings();
  }

  void renameLibrary(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final lib in _libraries) {
      if (lib.id != id) continue;
      if (lib.name == trimmed) return;
      lib.name = trimmed;
      notifyListeners();
      _saveSettings();
      return;
    }
  }

  /// 删除指定库。不删除文件和播放进度；只剩一个库时拒绝删除。
  void removeLibrary(String id) {
    if (_libraries.length <= 1) return;
    final before = _libraries.length;
    _libraries.removeWhere((lib) => lib.id == id);
    if (_libraries.length == before) return;
    if (_activeLibraryId == id) {
      _activeLibraryId = _libraries.first.id;
    }
    _lastFolderPaths = activeLibrary?.folderPaths ?? [];
    _pruneUnusedSharedFolders();
    notifyListeners();
    _saveSettings();
  }

  /// 切换激活库。调用方需要自行更新 [SlideProvider] 的文件夹并重扫。
  void switchLibrary(String id) {
    if (_activeLibraryId == id) return;
    if (!_libraries.any((lib) => lib.id == id)) return;
    _activeLibraryId = id;
    _lastFolderPaths = activeLibrary?.folderPaths ?? [];
    notifyListeners();
    _saveSettings();
  }

  /// 设置某个库是否隐藏。
  ///
  /// 若隐藏的正是当前激活库且还有其他未隐藏的库，会自动切换到第一个未隐藏
  /// 的库，避免当前库从列表中消失后无处可寻。此时返回 true，调用方需要同步
  /// [SlideProvider] 的文件夹；全部库都被隐藏时保持当前库不变并返回 false。
  bool setLibraryHidden(String id, bool hidden) {
    VideoLibrary? target;
    for (final lib in _libraries) {
      if (lib.id == id) {
        target = lib;
        break;
      }
    }
    if (target == null || target.hidden == hidden) return false;

    target.hidden = hidden;
    var activeChanged = false;
    if (hidden && _activeLibraryId == id) {
      for (final lib in _libraries) {
        if (!lib.hidden) {
          _activeLibraryId = lib.id;
          _lastFolderPaths = lib.folderPaths;
          activeChanged = true;
          break;
        }
      }
    }
    notifyListeners();
    _saveSettings();
    return activeChanged;
  }

  /// 查找包含指定视频路径的库（按文件夹路径前缀匹配）。
  ///
  /// 双击打开的视频可能位于库文件夹的任意子目录中，因此用前缀而非精确匹配。
  /// 同一文件夹可归属多个库，此时返回先命中的那个。找不到返回 null。
  ///
  /// [includeHidden] 为 false 时跳过隐藏库，保证切换到的是列表中可见的库。
  VideoLibrary? libraryContainingPath(
    String videoPath, {
    bool includeHidden = true,
  }) {
    final video = _normalizePath(videoPath);
    if (video.isEmpty) return null;
    for (final lib in _libraries) {
      if (!includeHidden && lib.hidden) continue;
      for (final folder in lib.folderPaths) {
        final root = _normalizePath(folder);
        if (root.isEmpty) continue;
        if (video == root || video.startsWith('$root/')) return lib;
      }
    }
    return null;
  }

  /// 双击打开视频时自动切换库：
  /// 若视频属于某个库且该库不是当前激活库，则切换并返回 true。
  ///
  /// 隐藏库仅在开启「显示隐藏媒体库」时才参与匹配：开关关闭时它不出现在
  /// 列表中，切过去会与界面状态矛盾。
  bool switchToLibraryForPath(String videoPath) {
    final lib = libraryContainingPath(
      videoPath,
      includeHidden: _showHiddenLibraries,
    );
    if (lib == null || lib.id == _activeLibraryId) return false;
    switchLibrary(lib.id);
    return true;
  }

  /// 归一化路径用于前缀比较：统一分隔符、去掉末尾分隔符，Windows 下忽略大小写
  static String _normalizePath(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  // 获取BoxFit枚举
  BoxFit get boxFit {
    switch (_videoFitMode) {
      case VideoFitMode.contain:
        return BoxFit.contain;
      case VideoFitMode.cover:
        return BoxFit.cover;
      case VideoFitMode.original:
        return BoxFit.none;
    }
  }

  // 加载设置
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _playOrder = PlayOrder
        .values[prefs.getInt('playOrder') ?? PlayOrder.newPreferred.index];
    final resumeIndex = (prefs.getInt('resumePlayback') ?? 0).clamp(
      0,
      ResumePlayback.values.length - 1,
    );
    _resumePlayback = ResumePlayback.values[resumeIndex];
    _loopPlay = prefs.getBool('loopPlay') ?? false;
    _autoPlay = prefs.getBool('autoPlay') ?? true;
    _videoFitMode = VideoFitMode.values[prefs.getInt('videoFitMode') ?? 0];
    final savedSubtitleFont = prefs.getString('subtitleFontFamily');
    _subtitleFontFamily =
        savedSubtitleFont == null || savedSubtitleFont.trim().isEmpty
        ? 'sans-serif'
        : savedSubtitleFont.trim();
    _subtitleFontSize =
        (prefs.getInt('subtitleFontSize') ?? subtitleFontSizeDefault).clamp(
          subtitleFontSizeMin,
          subtitleFontSizeMax,
        );
    _startFullscreen = prefs.getBool('startFullscreen') ?? true;
    _hideToolbar = prefs.getBool('hideToolbar') ?? true;
    _controlsHideDelay = prefs.getInt('controlsHideDelay') ?? 3;
    _keepControlsOnPause = prefs.getBool('keepControlsOnPause') ?? false;
    _recursiveScan = prefs.getBool('recursiveScan') ?? true;
    // 下标做边界保护，避免旧值越界导致启动崩溃
    final fileListInfoIndex = (prefs.getInt('fileListInfoMode') ?? 0).clamp(
      0,
      FileListInfo.values.length - 1,
    );
    _fileListInfo = FileListInfo.values[fileListInfoIndex];

    final browseLayoutIndex = (prefs.getInt('browseLayout') ?? 0).clamp(
      0,
      BrowseLayout.values.length - 1,
    );
    _browseLayout = BrowseLayout.values[browseLayoutIndex];

    _lastFolderPath = prefs.getString('lastFolderPath');
    final lastFolderPathsStr = prefs.getString('lastFolderPaths');
    if (lastFolderPathsStr != null) {
      _lastFolderPaths = json.decode(lastFolderPathsStr).cast<String>();
    }
    _showVideoInfo = prefs.getBool('showVideoInfo') ?? false;

    final excludedStr = prefs.getString('excludedPaths');
    if (excludedStr != null) {
      // 去掉历史数据中的重复路径，避免已排除统计翻倍
      _excludedPaths = json.decode(excludedStr).cast<String>().toSet().toList();
    }

    _localSortModes = _decodeStringMap(prefs.getString('localSortModes'));
    _sharedSortModes = _decodeStringMap(prefs.getString('sharedSortModes'));
    _localBrowseLayouts = _decodeStringMap(
      prefs.getString('localBrowseLayouts'),
    );
    _sharedBrowseLayouts = _decodeStringMap(
      prefs.getString('sharedBrowseLayouts'),
    );
    _lastCopyDestination = prefs.getString('lastCopyDestination');

    _wheelSwitchVideo = prefs.getBool('wheelSwitchVideo') ?? true;
    final arrowKeyActionIndex = (prefs.getInt('arrowKeyAction') ?? 0).clamp(
      0,
      ArrowKeyAction.values.length - 1,
    );
    _arrowKeyAction = ArrowKeyAction.values[arrowKeyActionIndex];
    final mobileTapIndex = (prefs.getInt('mobileTapAction') ?? 0).clamp(
      0,
      MobileTapAction.values.length - 1,
    );
    _mobileTapAction = MobileTapAction.values[mobileTapIndex];
    _addToContextMenu = prefs.getBool('addToContextMenu') ?? false;
    _deleteAction = DeleteAction.values[prefs.getInt('deleteAction') ?? 0];
    _videoOrientation =
        VideoOrientation.values[prefs.getInt('videoOrientation') ?? 2];
    _languageIndex = prefs.getInt('languageIndex') ?? 0;

    // 多媒体库：优先读取已保存的库列表；老用户只有 lastFolderPaths 时
    // 自动迁移为「默认媒体库」，文件夹、排序与进度都保持不变。
    _libraries = [];
    // 旧版本的库 JSON 没有 sharedFolderKeys / excludedPaths 字段，
    // 需要在读取完共享源与排除记录后把旧数据归入当前库（见下方）
    var legacyLibraryFormat = false;
    var legacyExcludedFormat = false;
    final librariesStr = prefs.getString('libraries');
    if (librariesStr != null) {
      try {
        final decoded = json.decode(librariesStr);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map && entry['sharedFolderKeys'] is! List) {
              legacyLibraryFormat = true;
            }
            if (entry is Map && entry['excludedPaths'] is! List) {
              legacyExcludedFormat = true;
            }
            final lib = VideoLibrary.fromJson(entry);
            if (lib != null) _libraries.add(lib);
          }
        }
      } catch (_) {
        // 数据损坏时忽略，走下方迁移逻辑
      }
    }
    _activeLibraryId = prefs.getString('activeLibraryId') ?? '';
    final hasActive = _libraries.any((lib) => lib.id == _activeLibraryId);
    if (_libraries.isEmpty && _lastFolderPaths.isNotEmpty) {
      final defaultLib = VideoLibrary(
        id: 'lib_default',
        name: _defaultLibraryName(),
        folderPaths: List<String>.of(_lastFolderPaths),
      );
      _libraries.add(defaultLib);
      _activeLibraryId = defaultLib.id;
    } else if (_libraries.isNotEmpty && !hasActive) {
      _activeLibraryId = _libraries.first.id;
    }
    _showHiddenLibraries = prefs.getBool('showHiddenLibraries') ?? false;

    // 旧版本没有按库区分排除记录：把旧的全局排除列表归入当前库，
    // 保证升级后「已排除」列表与之前一致。
    if (legacyExcludedFormat && _excludedPaths.isNotEmpty) {
      final lib = activeLibrary;
      if (lib != null && lib.excludedPaths.isEmpty) {
        lib.excludedPaths.addAll(_excludedPaths);
      }
    }

    // 内网共享
    _lanShareEnabled = prefs.getBool('lanShareEnabled') ?? false;
    _allowRemoteExclude = prefs.getBool('allowRemoteExclude') ?? false;
    _allowRemoteCopy = prefs.getBool('allowRemoteCopy') ?? false;
    _closeToTray = prefs.getBool('closeToTray') ?? false;
    _lanFolderSharing = {};
    final folderSharingStr = prefs.getString('lanFolderSharing');
    if (folderSharingStr != null) {
      try {
        final decoded = json.decode(folderSharingStr);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is bool) {
              _lanFolderSharing[entry.key as String] = entry.value as bool;
            }
          }
        }
      } catch (_) {
        // 存储损坏时退回默认（全部共享）
      }
    }

    _sharedFolders = [];
    final sharedFoldersStr = prefs.getString('sharedFolders');
    if (sharedFoldersStr != null) {
      try {
        final decoded = json.decode(sharedFoldersStr);
        if (decoded is List) {
          for (final entry in decoded) {
            final ref = SharedFolderRef.fromJson(entry);
            if (ref != null && !_sharedFolders.any((e) => e.key == ref.key)) {
              _sharedFolders.add(ref);
            }
          }
        }
      } catch (_) {
        // 存储损坏时忽略已添加的共享源
      }
    }

    // 旧版本的库没有共享绑定字段：把已登记的全部共享源归入当前库，
    // 保持升级前的可见范围不变。
    if (legacyLibraryFormat && _sharedFolders.isNotEmpty) {
      final lib = activeLibrary;
      if (lib != null) {
        for (final ref in _sharedFolders) {
          if (!lib.sharedFolderKeys.contains(ref.key)) {
            lib.sharedFolderKeys.add(ref.key);
          }
        }
      }
    }

    _deviceId = prefs.getString('deviceId') ?? '';
    if (_deviceId.isEmpty) {
      _deviceId = _generateDeviceId();
      await prefs.setString('deviceId', _deviceId);
    }
    final savedName = prefs.getString('deviceName');
    if (savedName != null && savedName.trim().isNotEmpty) {
      _deviceName = savedName;
    }

    notifyListeners();
  }

  // 保存设置
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('playOrder', _playOrder.index);
    await prefs.setInt('resumePlayback', _resumePlayback.index);
    await prefs.setBool('loopPlay', _loopPlay);
    await prefs.setBool('autoPlay', _autoPlay);
    await prefs.setInt('videoFitMode', _videoFitMode.index);
    await prefs.setString('subtitleFontFamily', _subtitleFontFamily);
    await prefs.setInt('subtitleFontSize', _subtitleFontSize);
    await prefs.setBool('startFullscreen', _startFullscreen);
    await prefs.setBool('hideToolbar', _hideToolbar);
    await prefs.setInt('controlsHideDelay', _controlsHideDelay);
    await prefs.setBool('keepControlsOnPause', _keepControlsOnPause);
    await prefs.setBool('recursiveScan', _recursiveScan);
    await prefs.setInt('fileListInfoMode', _fileListInfo.index);

    await prefs.setString('lastFolderPath', _lastFolderPath ?? '');
    await prefs.setString('lastFolderPaths', json.encode(_lastFolderPaths));
    await prefs.setInt('deleteAction', _deleteAction.index);
    await prefs.setBool('showVideoInfo', _showVideoInfo);
    await prefs.setInt('languageIndex', _languageIndex);
    await prefs.setBool('wheelSwitchVideo', _wheelSwitchVideo);
    await prefs.setInt('arrowKeyAction', _arrowKeyAction.index);
    await prefs.setInt('mobileTapAction', _mobileTapAction.index);
    await prefs.setBool('addToContextMenu', _addToContextMenu);
    // 兼容旧版本：把当前库的排除记录同步到旧的全局键（仅作降级兜底）
    final activeForExcluded = activeLibrary;
    await prefs.setString(
      'excludedPaths',
      json.encode(activeForExcluded?.excludedPaths ?? _excludedPaths),
    );
    await prefs.setString('localSortModes', json.encode(_localSortModes));
    await prefs.setString('sharedSortModes', json.encode(_sharedSortModes));
    await prefs.setInt('browseLayout', _browseLayout.index);
    await prefs.setString(
      'localBrowseLayouts',
      json.encode(_localBrowseLayouts),
    );
    await prefs.setString(
      'sharedBrowseLayouts',
      json.encode(_sharedBrowseLayouts),
    );
    if (_lastCopyDestination != null) {
      await prefs.setString('lastCopyDestination', _lastCopyDestination!);
    } else {
      await prefs.remove('lastCopyDestination');
    }
    await prefs.setInt('videoOrientation', _videoOrientation.index);

    // 内网共享
    await prefs.setBool('lanShareEnabled', _lanShareEnabled);
    await prefs.setBool('allowRemoteExclude', _allowRemoteExclude);
    await prefs.setBool('allowRemoteCopy', _allowRemoteCopy);
    await prefs.setBool('closeToTray', _closeToTray);
    await prefs.setString('lanFolderSharing', json.encode(_lanFolderSharing));
    await prefs.setString(
      'sharedFolders',
      json.encode(_sharedFolders.map((e) => e.toJson()).toList()),
    );
    await prefs.setString('deviceId', _deviceId);
    await prefs.setString('deviceName', _deviceName);

    // 多媒体库
    await prefs.setString(
      'libraries',
      json.encode(_libraries.map((e) => e.toJson()).toList()),
    );
    await prefs.setString('activeLibraryId', _activeLibraryId);
    await prefs.setBool('showHiddenLibraries', _showHiddenLibraries);
  }

  /// 把持久化的浏览格式 id 还原为枚举；未知 id 返回 null
  static BrowseLayout? parseBrowseLayout(String? id) {
    if (id == null) return null;
    for (final layout in BrowseLayout.values) {
      if (layout.name == id) return layout;
    }
    return null;
  }

  /// 解析存储为 JSON 的「字符串 → 字符串」映射，数据损坏时返回空表
  static Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null) return {};
    try {
      final decoded = json.decode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        };
      }
    } catch (_) {
      // 数据损坏时退回空表
    }
    return {};
  }

  /// 老数据迁移时创建的默认库名称。
  ///
  /// 通过 [AppLocalizations.fromIndex] 解析语言：索引 0（跟随系统）会按系统
  /// 语言选择文案，其余索引与 [AppLanguage] 枚举一致。
  String _defaultLibraryName() {
    final loc = AppLocalizations.fromIndex(_languageIndex);
    if (loc.isEn) return 'Default Library';
    if (loc.isZhTW) return '預設媒體庫';
    return '默认媒体库';
  }

  /// 设备名称：桌面端用主机名，其余平台用系统标识
  static String _defaultDeviceName() {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final host = Platform.localHostname.trim();
        if (host.isNotEmpty) return host;
      }
    } catch (_) {
      // 读取失败时使用固定名称
    }
    return 'SteamFlow';
  }

  /// 首次启动时生成一次设备标识并持久化，供其他设备稳定识别
  static String _generateDeviceId() {
    final random = Random();
    final suffix = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}$suffix';
  }
}
