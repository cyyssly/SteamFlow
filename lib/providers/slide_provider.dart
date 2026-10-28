import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/utils/filename_compare.dart';

class SlideProvider extends ChangeNotifier {
  List<VideoItem> _videos = [];
  List<int> _randomOrder = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  List<String> _folderPaths = [];

  /// 是否按传入列表的既有顺序播放（从瀑布流进入时为其当前排序）
  bool _followListOrder = false;

  List<VideoItem> get videos => _videos;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;

  /// 是否按传入列表的既有顺序播放
  bool get followListOrder => _followListOrder;
  String get folderPath => _folderPaths.isNotEmpty ? _folderPaths.first : '';
  List<String> get folderPaths => _folderPaths;

  void setVideos(
    List<VideoItem> videos, {
    PlayOrder? playOrder,
    bool followListOrder = false,
  }) {
    _videos = videos;
    _followListOrder = followListOrder;
    _randomOrder = List.generate(videos.length, (i) => i)..shuffle();
    _currentIndex = (playOrder == PlayOrder.random && _randomOrder.isNotEmpty)
        ? _randomOrder[0]
        : 0;
    notifyListeners();
  }

  void addVideos(List<VideoItem> videos) {
    for (final video in videos) {
      if (!_videos.any((existing) => existing.key == video.key)) {
        _videos.add(video);
      }
    }
    _randomOrder = List.generate(_videos.length, (i) => i)..shuffle();
    notifyListeners();
  }

  void setFolderPath(String path) {
    _folderPaths = [path];
    notifyListeners();
  }

  void setFolderPaths(List<String> paths) {
    _folderPaths = paths;
    notifyListeners();
  }

  void addFolderPath(String path) {
    if (!_folderPaths.contains(path)) {
      _folderPaths.add(path);
      notifyListeners();
    }
  }

  void removeFolderPath(String path) {
    _folderPaths.remove(path);
    notifyListeners();
  }

  void clearFolderPaths() {
    _folderPaths.clear();
    notifyListeners();
  }

  void nextVideo({bool random = false}) {
    if (_videos.isEmpty) return;
    if (random) {
      _currentIndex = (_currentIndex + 1) % _videos.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _videos.length;
    }
    notifyListeners();
  }

  void nextRandomVideo() {
    if (_videos.isEmpty || _randomOrder.isEmpty) return;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 获取下一个随机索引（循环）
    final nextPos = (currentPos + 1) % _randomOrder.length;
    _currentIndex = _randomOrder[nextPos];

    notifyListeners();
  }

  bool isRandomPlaybackComplete() {
    if (_videos.isEmpty || _randomOrder.isEmpty) return false;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 如果当前位置是随机序列的最后一个，说明播放完毕
    return currentPos == _randomOrder.length - 1;
  }

  void prevVideo({PlayOrder? playOrder}) {
    if (_videos.isEmpty) return;

    if (playOrder == PlayOrder.random && _randomOrder.isNotEmpty) {
      // 随机模式：回溯预打乱的随机序列
      final currentPos = _randomOrder.indexOf(_currentIndex);
      if (currentPos > 0) {
        _currentIndex = _randomOrder[currentPos - 1];
      } else {
        // 当前是随机序列的第一个，回到最后一个
        _currentIndex = _randomOrder[_randomOrder.length - 1];
      }
    } else {
      // 顺序模式：正常递减
      _currentIndex = (_currentIndex - 1 + _videos.length) % _videos.length;
    }
    notifyListeners();
  }

  void goToStartPosition(PlayOrder playOrder) {
    if (_videos.isEmpty) return;
    if (playOrder == PlayOrder.random && _randomOrder.isNotEmpty) {
      _currentIndex = _randomOrder[0];
    } else {
      _currentIndex = 0;
    }
    notifyListeners();
  }

  void goToVideo(int index) {
    if (index >= 0 && index < _videos.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  void removeVideo(int index) {
    if (index < 0 || index >= _videos.length) return;

    // 移除视频
    _videos.removeAt(index);

    // 更新随机序列
    _randomOrder.remove(index);
    // 调整随机序列中大于被删除索引的值
    for (int i = 0; i < _randomOrder.length; i++) {
      if (_randomOrder[i] > index) {
        _randomOrder[i]--;
      }
    }

    // 如果被删除的是最后一个视频，当前索引回退到最后一个
    if (_currentIndex >= _videos.length) {
      _currentIndex = _videos.isNotEmpty ? _videos.length - 1 : 0;
    }
    // 如果被删除的是当前视频之前的视频，当前索引减1
    else if (_currentIndex > index) {
      _currentIndex--;
    }

    notifyListeners();
  }

  void togglePlay() {
    _isPlaying = !_isPlaying;
    notifyListeners();
  }

  void startPlay() {
    if (!_isPlaying) {
      _isPlaying = true;
      notifyListeners();
    }
  }

  void stopPlay() {
    if (_isPlaying) {
      _isPlaying = false;
      notifyListeners();
    }
  }

  void clearVideos() {
    _videos = [];
    _currentIndex = 0;
    _isPlaying = false;
    _folderPaths.clear();
    _randomOrder = [];
    _followListOrder = false;
    notifyListeners();
  }

  void shuffleVideos() {
    _randomOrder = List.generate(_videos.length, (i) => i)..shuffle();
    notifyListeners();
  }

  /// 重新洗牌开始下一轮，并保证新顺序的第一个不是刚播完的那个视频。
  ///
  /// 只做一次「与随机另一位置交换」：比反复重抽更简单（一次必成功），
  /// 也不会像「本轮跳过」那样改变这一轮实际会播的视频数量。
  void reshuffleForNextRound() {
    if (_videos.length <= 1) return;
    shuffleVideos();
    if (_randomOrder.isEmpty || _randomOrder.first != _currentIndex) return;
    final swapPos =
        1 + DateTime.now().microsecondsSinceEpoch % (_randomOrder.length - 1);
    final first = _randomOrder[0];
    _randomOrder[0] = _randomOrder[swapPos];
    _randomOrder[swapPos] = first;
    notifyListeners();
  }

  /// 增量添加新视频（边扫描边播放时使用）
  /// 按排序顺序插入到正确位置，保证列表始终有序，不重置当前索引
  void addNewVideos(List<VideoItem> newVideos, PlayOrder order) {
    int addedCount = 0;
    for (final video in newVideos) {
      if (_videos.any((existing) => existing.path == video.path)) continue;

      int insertIndex;
      switch (order) {
        case PlayOrder.sequential:
          insertIndex = _findInsertIndexByName(video.name);
          break;
        case PlayOrder.reverseSequential:
          insertIndex = _findInsertIndexByNameDescending(video.name);
          break;
        case PlayOrder.newestFirst:
          insertIndex = _findInsertIndexByTime(video.path, newestFirst: true);
          break;
        case PlayOrder.oldestFirst:
          insertIndex = _findInsertIndexByTime(video.path, newestFirst: false);
          break;
        case PlayOrder.sizeLargest:
          insertIndex = _findInsertIndexBySize(video, largestFirst: true);
          break;
        case PlayOrder.sizeSmallest:
          insertIndex = _findInsertIndexBySize(video, largestFirst: false);
          break;
        case PlayOrder.random:
          insertIndex = _videos.length;
          break;
        case PlayOrder.newPreferred:
          insertIndex = _videos.length;
          break;
      }

      _videos.insert(insertIndex, video);

      // 插入位置在当前索引之前或当前位置 → 当前索引后移
      if (insertIndex <= _currentIndex) {
        _currentIndex++;
      }

      // 更新随机序列
      _randomOrder.add(_randomOrder.length); // 先加一个占位
      // 调整已有索引：插入点之后的索引 +1
      for (int i = 0; i < _randomOrder.length - 1; i++) {
        if (_randomOrder[i] >= insertIndex) {
          _randomOrder[i]++;
        }
      }
      // 新索引随机插入到随机序列中
      final randomPos =
          DateTime.now().microsecondsSinceEpoch % (_randomOrder.length);
      if (randomPos == _randomOrder.length - 1) {
        // 正好选中末尾的占位符，直接替换
        _randomOrder[randomPos] = insertIndex;
      } else {
        // 交换 randomPos 与末尾的值，将新索引插入到 randomPos 位置
        _randomOrder[_randomOrder.length - 1] = _randomOrder[randomPos];
        _randomOrder[randomPos] = insertIndex;
      }

      addedCount++;
    }

    if (addedCount > 0) {
      notifyListeners();
    }
  }

  /// 二分查找按文件名的插入位置（列表已按文件名升序排列）
  int _findInsertIndexByName(String name) {
    int low = 0, high = _videos.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (compareFileNames(_videos[mid].name, name) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 二分查找按文件名的插入位置（列表已按文件名**降序**排列）
  int _findInsertIndexByNameDescending(String name) {
    int low = 0, high = _videos.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (compareFileNames(_videos[mid].name, name) > 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 二分查找按修改时间的插入位置
  /// [newestFirst] = true: 从新到旧（降序），false: 从旧到新（升序）
  int _findInsertIndexByTime(String videoPath, {required bool newestFirst}) {
    DateTime? newTime;
    try {
      newTime = File(videoPath).lastModifiedSync();
    } catch (_) {
      return _videos.length; // 无法获取时间，放到末尾
    }

    int low = 0, high = _videos.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      DateTime? midTime;
      try {
        midTime = File(_videos[mid].path).lastModifiedSync();
      } catch (_) {
        midTime = newestFirst ? DateTime(0) : DateTime(9999);
      }

      final cmp = midTime.compareTo(newTime);
      // newestFirst: 降序（新→旧），所以 new > mid 时靠前
      final adjusted = newestFirst ? -cmp : cmp;
      if (adjusted < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 二分查找按文件大小的插入位置
  /// [largestFirst] = true: 由大到小（降序），false: 由小到大（升序）
  int _findInsertIndexBySize(VideoItem video, {required bool largestFirst}) {
    int low = 0, high = _videos.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_compareBySize(_videos[mid], video, largestFirst: largestFirst) <=
          0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 读取视频大小：远端视频直接使用其提供的值，本地视频回退到文件系统。
  static int _sizeOf(VideoItem item) {
    final known = item.sizeBytes;
    if (known != null) return known;
    if (item.path.isEmpty) return 0;
    try {
      return File(item.path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// 按文件大小比较
  static int _compareBySize(
    VideoItem a,
    VideoItem b, {
    required bool largestFirst,
  }) {
    final aSize = _sizeOf(a);
    final bSize = _sizeOf(b);
    return largestFirst ? bSize.compareTo(aSize) : aSize.compareTo(bSize);
  }

  /// 根据播放顺序模式对视频列表进行排序
  void sortByPlayOrder(PlayOrder order) {
    switch (order) {
      case PlayOrder.sequential:
        // 按文件名排序（默认）——中文拼音 + 自然排序
        _videos.sort((a, b) => compareFileNames(a.name, b.name));
        break;
      case PlayOrder.reverseSequential:
        // 按文件名逆序
        _videos.sort((a, b) => compareFileNames(b.name, a.name));
        break;
      case PlayOrder.newestFirst:
        // 按修改时间从新到旧
        _videos.sort(
          (a, b) => _modifiedTimeOf(b).compareTo(_modifiedTimeOf(a)),
        );
        break;
      case PlayOrder.oldestFirst:
        // 按修改时间从旧到新
        _videos.sort(
          (a, b) => _modifiedTimeOf(a).compareTo(_modifiedTimeOf(b)),
        );
        break;
      case PlayOrder.sizeLargest:
        // 按文件大小从大到小
        _videos.sort((a, b) => _compareBySize(a, b, largestFirst: true));
        break;
      case PlayOrder.sizeSmallest:
        // 按文件大小从小到大
        _videos.sort((a, b) => _compareBySize(a, b, largestFirst: false));
        break;
      case PlayOrder.random:
        // 随机模式不排序视频本身，使用 `_randomOrder` 序列
        break;
      case PlayOrder.newPreferred:
        applyNewPreferredOrder(_videos);
        break;
    }
    _currentIndex = 0;
    _randomOrder = List.generate(_videos.length, (i) => i)..shuffle();
    notifyListeners();
  }

  /// 新视频优先排序：先按修改时间从新到旧，再做加权随机重排，
  /// 越新的视频偏移范围越小，因此更大概率保留在靠前位置。
  ///
  /// 瀑布流页面与播放顺序共用该逻辑，保证两边看到的新视频顺序一致。
  static void applyNewPreferredOrder(List<VideoItem> items) {
    if (items.length < 2) return;
    items.sort((a, b) => _modifiedTimeOf(b).compareTo(_modifiedTimeOf(a)));
    final rng = Random();
    for (int i = 0; i < items.length; i++) {
      final progress = i / items.length; // 0~1
      // 偏移范围：前部30% → 后部90%，逐步增大
      final rangeRatio = 0.3 + progress * 0.6;
      final maxOffset = (items.length * rangeRatio).ceil().clamp(
        1,
        items.length - i,
      );
      final j = i + rng.nextInt(maxOffset);
      if (j < items.length) {
        final temp = items[i];
        items[i] = items[j];
        items[j] = temp;
      }
    }
  }

  /// 读取视频修改时间：优先用扫描/远端已带的时间，
  /// 缺失时才回退到本地文件系统（远端条目的 path 为空）。
  static DateTime _modifiedTimeOf(VideoItem item) {
    final known = item.modifiedTime;
    if (known != null) return known;
    try {
      return File(item.path).lastModifiedSync();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}
