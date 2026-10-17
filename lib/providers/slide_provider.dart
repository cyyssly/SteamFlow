import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:steam_flow/models/image_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';

class SlideProvider extends ChangeNotifier {
  List<ImageItem> _images = [];
  List<int> _randomOrder = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  int _interval = 3000;
  List<String> _folderPaths = [];

  List<ImageItem> get images => _images;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  int get interval => _interval;
  String get folderPath => _folderPaths.isNotEmpty ? _folderPaths.first : '';
  List<String> get folderPaths => _folderPaths;

  void setImages(List<ImageItem> images, {PlayOrder? playOrder}) {
    _images = images;
    _randomOrder = List.generate(images.length, (i) => i)..shuffle();
    _currentIndex = (playOrder == PlayOrder.random && _randomOrder.isNotEmpty)
        ? _randomOrder[0]
        : 0;
    notifyListeners();
  }

  void addImages(List<ImageItem> images) {
    for (final image in images) {
      if (!_images.any((img) => img.path == image.path)) {
        _images.add(image);
      }
    }
    _randomOrder = List.generate(_images.length, (i) => i)..shuffle();
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

  void nextImage({bool random = false}) {
    if (_images.isEmpty) return;
    if (random) {
      _currentIndex = (_currentIndex + 1) % _images.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _images.length;
    }
    notifyListeners();
  }

  void nextRandomImage() {
    if (_images.isEmpty || _randomOrder.isEmpty) return;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 获取下一个随机索引（循环）
    final nextPos = (currentPos + 1) % _randomOrder.length;
    _currentIndex = _randomOrder[nextPos];

    notifyListeners();
  }

  bool isRandomPlaybackComplete() {
    if (_images.isEmpty || _randomOrder.isEmpty) return false;

    // 找到当前索引在随机序列中的位置
    final currentPos = _randomOrder.indexOf(_currentIndex);

    // 如果当前位置是随机序列的最后一个，说明播放完毕
    return currentPos == _randomOrder.length - 1;
  }

  void prevImage({PlayOrder? playOrder}) {
    if (_images.isEmpty) return;

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
      _currentIndex = (_currentIndex - 1 + _images.length) % _images.length;
    }
    notifyListeners();
  }

  void goToStartPosition(PlayOrder playOrder) {
    if (_images.isEmpty) return;
    if (playOrder == PlayOrder.random && _randomOrder.isNotEmpty) {
      _currentIndex = _randomOrder[0];
    } else {
      _currentIndex = 0;
    }
    notifyListeners();
  }

  void goToImage(int index) {
    if (index >= 0 && index < _images.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  void removeImage(int index) {
    if (index < 0 || index >= _images.length) return;

    // 移除图片
    _images.removeAt(index);

    // 更新随机序列
    _randomOrder.remove(index);
    // 调整随机序列中大于被删除索引的值
    for (int i = 0; i < _randomOrder.length; i++) {
      if (_randomOrder[i] > index) {
        _randomOrder[i]--;
      }
    }

    // 如果被删除的是最后一张图片，当前索引回退到最后一张
    if (_currentIndex >= _images.length) {
      _currentIndex = _images.isNotEmpty ? _images.length - 1 : 0;
    }
    // 如果被删除的是当前图片之前的图片，当前索引减1
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

  void setInterval(int milliseconds) {
    _interval = milliseconds;
    notifyListeners();
  }

  void clearImages() {
    _images = [];
    _currentIndex = 0;
    _isPlaying = false;
    _folderPaths.clear();
    _randomOrder = [];
    notifyListeners();
  }

  void shuffleImages() {
    _randomOrder = List.generate(_images.length, (i) => i)..shuffle();
    notifyListeners();
  }

  /// 增量添加新图片（边扫描边播放时使用）
  /// 按排序顺序插入到正确位置，保证列表始终有序，不重置当前索引
  void addNewImages(List<ImageItem> newImages, PlayOrder order) {
    int addedCount = 0;
    for (final image in newImages) {
      if (_images.any((existing) => existing.path == image.path)) continue;

      int insertIndex;
      switch (order) {
        case PlayOrder.sequential:
          insertIndex = _findInsertIndexByName(image.name);
          break;
        case PlayOrder.reverseSequential:
          insertIndex = _findInsertIndexByNameDescending(image.name);
          break;
        case PlayOrder.newestFirst:
          insertIndex = _findInsertIndexByTime(image.path, newestFirst: true);
          break;
        case PlayOrder.oldestFirst:
          insertIndex = _findInsertIndexByTime(image.path, newestFirst: false);
          break;
        case PlayOrder.random:
          insertIndex = _images.length;
          break;
        case PlayOrder.newPreferred:
          insertIndex = _images.length;
          break;
      }

      _images.insert(insertIndex, image);

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
    int low = 0, high = _images.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_images[mid].name.compareTo(name) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 二分查找按文件名的插入位置（列表已按文件名**降序**排列）
  int _findInsertIndexByNameDescending(String name) {
    int low = 0, high = _images.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_images[mid].name.compareTo(name) > 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 二分查找按修改时间的插入位置
  /// [newestFirst] = true: 从新到旧（降序），false: 从旧到新（升序）
  int _findInsertIndexByTime(String imagePath, {required bool newestFirst}) {
    DateTime? newTime;
    try {
      newTime = File(imagePath).lastModifiedSync();
    } catch (_) {
      return _images.length; // 无法获取时间，放到末尾
    }

    int low = 0, high = _images.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      DateTime? midTime;
      try {
        midTime = File(_images[mid].path).lastModifiedSync();
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

  /// 根据播放顺序模式对图片列表进行排序
  void sortByPlayOrder(PlayOrder order) {
    switch (order) {
      case PlayOrder.sequential:
        // 按文件名排序（默认）
        _images.sort((a, b) => a.name.compareTo(b.name));
        break;
      case PlayOrder.reverseSequential:
        // 按文件名逆序
        _images.sort((a, b) => b.name.compareTo(a.name));
        break;
      case PlayOrder.newestFirst:
        // 按文件修改时间从新到旧
        _images.sort((a, b) {
          try {
            final aTime = File(a.path).lastModifiedSync();
            final bTime = File(b.path).lastModifiedSync();
            return bTime.compareTo(aTime);
          } catch (_) {
            return 0;
          }
        });
        break;
      case PlayOrder.oldestFirst:
        // 按文件修改时间从旧到新
        _images.sort((a, b) {
          try {
            final aTime = File(a.path).lastModifiedSync();
            final bTime = File(b.path).lastModifiedSync();
            return aTime.compareTo(bTime);
          } catch (_) {
            return 0;
          }
        });
        break;
      case PlayOrder.random:
        // 随机模式不排序图片本身，使用 `_randomOrder` 序列
        break;
      case PlayOrder.newPreferred:
        // 新图优先：加权随机重排，新图有更高概率放在前面
        // 1. 先按修改时间从新到旧排序
        _images.sort((a, b) {
          try {
            final aTime = File(a.path).lastModifiedSync();
            final bTime = File(b.path).lastModifiedSync();
            return bTime.compareTo(aTime);
          } catch (_) {
            return 0;
          }
        });
        // 2. 加权随机打乱：越新的图偏移越小，保留靠前位置
        final rng = Random();
        for (int i = 0; i < _images.length; i++) {
          final progress = i / _images.length; // 0~1
          // 偏移范围：前部30% → 后部90%，逐步增大
          final rangeRatio = 0.3 + progress * 0.6;
          final maxOffset = (_images.length * rangeRatio).ceil().clamp(
            1,
            _images.length - i,
          );
          final j = i + rng.nextInt(maxOffset);
          if (j < _images.length) {
            final temp = _images[i];
            _images[i] = _images[j];
            _images[j] = temp;
          }
        }
        break;
    }
    _currentIndex = 0;
    _randomOrder = List.generate(_images.length, (i) => i)..shuffle();
    notifyListeners();
  }
}
