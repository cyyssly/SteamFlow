import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}

enum VideoFitMode { contain, cover, original }

enum BackgroundColor { black, darkGray, white }

enum TransitionAnimation { none, fade, slideLeft, slideUp }

enum DeleteAction {
  exclude, // 排除播放
  delete, // 实际删除
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

class SettingsProvider extends ChangeNotifier {
  // 播放基础设置
  PlayOrder _playOrder = PlayOrder.newPreferred;
  bool _loopPlay = false;
  bool _autoPlay = true;

  // 视频显示设置
  VideoFitMode _videoFitMode = VideoFitMode.contain;
  BackgroundColor _backgroundColor = BackgroundColor.black;
  VideoOrientation _videoOrientation = VideoOrientation.followSystem;

  // 切换动画
  TransitionAnimation _transitionAnimation = TransitionAnimation.fade;
  double _animationDuration = 0.5;

  // 窗口/全屏控制
  bool _startFullscreen = true;
  bool _hideToolbar = true;
  int _controlsHideDelay = 3;
  bool _keepControlsOnPause = false;

  // 文件与目录相关
  bool _recursiveScan = true;
  FileListInfo _fileListInfo = FileListInfo.none;

  String? _lastFolderPath;
  List<String> _lastFolderPaths = [];

  // 视频底部信息条是否显示（自动隐藏跟随「工具栏」设置统一控制）
  bool _showVideoInfo = false;

  // 快捷键与控制
  bool _wheelSwitchVideo = true;

  // 删除行为设置
  DeleteAction _deleteAction = DeleteAction.exclude;
  List<String> _excludedPaths = [];

  // 语言设置（0=跟随系统, 1=简体中文, 2=English, 3=繁體中文）
  int _languageIndex = 0;

  // Getters
  List<String> get excludedPaths => List.unmodifiable(_excludedPaths);
  PlayOrder get playOrder => _playOrder;
  bool get loopPlay => _loopPlay;
  bool get autoPlay => _autoPlay;
  VideoFitMode get videoFitMode => _videoFitMode;
  BackgroundColor get backgroundColor => _backgroundColor;
  VideoOrientation get videoOrientation => _videoOrientation;
  TransitionAnimation get transitionAnimation => _transitionAnimation;
  double get animationDuration => _animationDuration;
  bool get startFullscreen => _startFullscreen;
  bool get hideToolbar => _hideToolbar;
  int get controlsHideDelay => _controlsHideDelay;
  bool get keepControlsOnPause => _keepControlsOnPause;
  bool get recursiveScan => _recursiveScan;
  FileListInfo get fileListInfo => _fileListInfo;

  String? get lastFolderPath => _lastFolderPath;
  List<String> get lastFolderPaths => _lastFolderPaths;

  bool get showVideoInfo => _showVideoInfo;
  bool get wheelSwitchVideo => _wheelSwitchVideo;
  DeleteAction get deleteAction => _deleteAction;
  int get languageIndex => _languageIndex;

  // Setters
  void setPlayOrder(PlayOrder value) {
    _playOrder = value;
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

  void setTransitionAnimation(TransitionAnimation value) {
    _transitionAnimation = value;
    notifyListeners();
    _saveSettings();
  }

  void setAnimationDuration(double value) {
    _animationDuration = value;
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
    _excludedPaths.remove(path);
    notifyListeners();
    _saveSettings();
  }

  void clearExcludedPaths() {
    _excludedPaths.clear();
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
    _loopPlay = prefs.getBool('loopPlay') ?? false;
    _autoPlay = prefs.getBool('autoPlay') ?? true;
    _videoFitMode = VideoFitMode.values[prefs.getInt('videoFitMode') ?? 0];
    _backgroundColor =
        BackgroundColor.values[prefs.getInt('backgroundColor') ?? 0];
    // 下标做边界保护：旧版本枚举里还有 slideRight/slideDown，
    // 若用户存过越界下标，直接取值会 RangeError 导致启动崩溃
    final animationIndex = (prefs.getInt('transitionAnimation') ?? 1).clamp(
      0,
      TransitionAnimation.values.length - 1,
    );
    _transitionAnimation = TransitionAnimation.values[animationIndex];
    _animationDuration = prefs.getDouble('animationDuration') ?? 0.5;
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

    _lastFolderPath = prefs.getString('lastFolderPath');
    final lastFolderPathsStr = prefs.getString('lastFolderPaths');
    if (lastFolderPathsStr != null) {
      _lastFolderPaths = json.decode(lastFolderPathsStr).cast<String>();
    }
    _showVideoInfo = prefs.getBool('showVideoInfo') ?? false;

    final excludedStr = prefs.getString('excludedPaths');
    if (excludedStr != null) {
      _excludedPaths = json.decode(excludedStr).cast<String>();
    }

    _wheelSwitchVideo = prefs.getBool('wheelSwitchVideo') ?? true;
    _deleteAction = DeleteAction.values[prefs.getInt('deleteAction') ?? 0];
    _videoOrientation =
        VideoOrientation.values[prefs.getInt('videoOrientation') ?? 2];
    _languageIndex = prefs.getInt('languageIndex') ?? 0;

    notifyListeners();
  }

  // 保存设置
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('playOrder', _playOrder.index);
    await prefs.setBool('loopPlay', _loopPlay);
    await prefs.setBool('autoPlay', _autoPlay);
    await prefs.setInt('videoFitMode', _videoFitMode.index);
    await prefs.setInt('backgroundColor', _backgroundColor.index);
    await prefs.setInt('transitionAnimation', _transitionAnimation.index);
    await prefs.setDouble('animationDuration', _animationDuration);
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
    await prefs.setString('excludedPaths', json.encode(_excludedPaths));
    await prefs.setInt('videoOrientation', _videoOrientation.index);
  }
}
