import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steam_flow/models/lan_models.dart';

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

enum BackgroundColor { black, darkGray, white }

enum DeleteAction {
  exclude, // 排除播放
  delete, // 实际删除
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
  // 播放基础设置
  PlayOrder _playOrder = PlayOrder.newPreferred;
  ResumePlayback _resumePlayback = ResumePlayback.resume;
  bool _loopPlay = false;
  bool _autoPlay = true;

  // 视频显示设置
  VideoFitMode _videoFitMode = VideoFitMode.contain;
  BackgroundColor _backgroundColor = BackgroundColor.black;
  VideoOrientation _videoOrientation = VideoOrientation.followSystem;

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

  // 视频底部信息条是否显示（自动隐藏跟随「工具栏」设置统一控制）
  bool _showVideoInfo = false;

  // 快捷键与控制
  bool _wheelSwitchVideo = true;

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
  List<String> get excludedPaths => List.unmodifiable(_excludedPaths);

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
  BackgroundColor get backgroundColor => _backgroundColor;
  VideoOrientation get videoOrientation => _videoOrientation;
  bool get startFullscreen => _startFullscreen;
  bool get hideToolbar => _hideToolbar;
  int get controlsHideDelay => _controlsHideDelay;
  bool get keepControlsOnPause => _keepControlsOnPause;
  bool get recursiveScan => _recursiveScan;
  FileListInfo get fileListInfo => _fileListInfo;
  BrowseLayout get browseLayout => _browseLayout;

  String? get lastFolderPath => _lastFolderPath;
  List<String> get lastFolderPaths => _lastFolderPaths;

  bool get showVideoInfo => _showVideoInfo;
  bool get wheelSwitchVideo => _wheelSwitchVideo;
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

  List<SharedFolderRef> get sharedFolders => List.unmodifiable(_sharedFolders);

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

  void setBackgroundColor(BackgroundColor value) {
    _backgroundColor = value;
    notifyListeners();
    _saveSettings();
  }

  void setVideoOrientation(VideoOrientation value) {
    _videoOrientation = value;
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
    _lastFolderPaths = value;
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
    if (!_excludedPaths.contains(path)) {
      _excludedPaths.add(path);
      notifyListeners();
      _saveSettings();
    }
  }

  void removeExcludedPath(String path) {
    final before = _excludedPaths.length;
    // 历史数据里可能存在重复路径，这里一次性全部移除
    _excludedPaths.removeWhere((item) => item == path);
    if (_excludedPaths.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  /// 批量移除已排除路径（恢复某个文件夹分组时使用）
  void removeExcludedPaths(Iterable<String> paths) {
    final targets = paths.toSet();
    if (targets.isEmpty) return;
    final before = _excludedPaths.length;
    _excludedPaths.removeWhere(targets.contains);
    if (_excludedPaths.length == before) return;
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    _excludedPaths.clear();
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

  void addSharedFolder(SharedFolderRef ref) {
    _sharedFolders.removeWhere((item) => item.key == ref.key);
    _sharedFolders.add(ref);
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

  void removeSharedFolder(String key) {
    final before = _sharedFolders.length;
    _sharedFolders.removeWhere((item) => item.key == key);
    if (_sharedFolders.length == before) return;
    notifyListeners();
    _saveSettings();
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

  // 获取背景颜色
  Color get background {
    switch (_backgroundColor) {
      case BackgroundColor.black:
        return Colors.black;
      case BackgroundColor.darkGray:
        return const Color(0xFF333333);
      case BackgroundColor.white:
        return Colors.white;
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
    _backgroundColor =
        BackgroundColor.values[prefs.getInt('backgroundColor') ?? 0];
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
    await prefs.setInt('backgroundColor', _backgroundColor.index);
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
    await prefs.setInt('mobileTapAction', _mobileTapAction.index);
    await prefs.setBool('addToContextMenu', _addToContextMenu);
    await prefs.setString('excludedPaths', json.encode(_excludedPaths));
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
