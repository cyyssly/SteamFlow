import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/services/fullscreen_service.dart';
import 'package:steam_flow/services/video_scan_service.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/widgets/masonry_video_grid.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 瀑布流排序方式
enum _SortMode { byName, byTime, random }

/// 文件夹视频瀑布流浏览页
///
/// 卡片悬停时只显示一个右下角按钮，其行为由「删除行为」设置决定：
/// 排除播放或实际删除。
class FolderVideosScreen extends StatefulWidget {
  final String folderPath;

  const FolderVideosScreen({super.key, required this.folderPath});

  @override
  State<FolderVideosScreen> createState() => _FolderVideosScreenState();
}

class _FolderVideosScreenState extends State<FolderVideosScreen> {
  /// 全部视频（扫描结果）
  List<VideoItem> _allItems = [];

  /// 当前已显示在瀑布流中的视频
  List<VideoItem> _items = [];
  bool _isLoading = true;
  int? _selectedIndex;

  /// 每批加载的视频数量
  static const _pageSize = 30;

  /// 已加载到内存的视频数量（宽高比与预解码都已就绪）
  int _loadedCount = 0;

  /// 是否正在预加载（防止重复触发）
  bool _isPreloading = false;

  /// 当前排序方式
  _SortMode _sortMode = _SortMode.byName;

  /// 顺序模式下是否为升序（true = 顺序，false = 逆序）
  bool _nameAscending = true;

  /// 最新模式下是否最新在前（true = 最新，false = 最旧）
  bool _newestFirst = true;

  /// 批次代次：每次重新排序都自增，使跨越排序、尚在途中的旧批次作废，
  /// 避免把「旧顺序下的这一批已就绪」错误地记到新顺序的批次边界上。
  int _batchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadVideos();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  /// 键盘快捷键：F11 切换全屏
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，而播放页也注册了
  /// F11，因此这里必须确认本页位于最上层，否则同一次按键会被两页各处理一次
  /// （先进全屏再退全屏，等于没反应）。
  /// 全屏切换只由 F11 负责，ESC 不再具备退出全屏功能。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return true;
    }
    return false;
  }

  void _toggleFullscreen() {
    if (FullscreenService.instance.isFullscreen) {
      FullscreenService.instance.exit();
    } else {
      FullscreenService.instance.enter();
    }
  }

  Future<void> _loadVideos() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final items = await VideoScanService.scanFolder(
      widget.folderPath,
      settings,
    );
    if (!mounted) return;
    setState(() {
      _allItems = items;
      // 首屏按当前排序方式排列（默认：文件名顺序）
      _applySortToAllItems();
      _items = _allItems.take(_pageSize).toList();
      // 视频不足一页时不要记成 30，否则 _loadMore 会取到空区间
      _loadedCount = _allItems.length.clamp(0, _pageSize);
      _isLoading = false;
    });
    await _bootstrapBatches();
  }

  /// 首批加载：先读出宽高比（决定卡片高度），再真正预解码像素，
  /// 最后预加载下一批，保证首屏与滚动时都无需等待。
  Future<void> _bootstrapBatches() async {
    await _loadAspectRatios(_items);
    // 预解码当前批，首屏没有滚动通知，必须主动解码
    unawaited(_precacheBatch(_items));
    // 预加载下一批，保证滚动时无需等待
    unawaited(_preloadNextBatch());
  }

  /// 预加载下一批：
  /// 1. 先读出该批的宽高比（决定卡片高度）
  /// 2. 真正解码像素（填充 ImageCache），这是消除滚动卡顿的关键
  /// 3. 两者都就绪后才把该批标记为"可显示"，避免卡片先按正方形渲染再重排跳变
  Future<void> _preloadNextBatch() async {
    if (_isPreloading) return;
    if (_loadedCount >= _allItems.length) return;
    _isPreloading = true;
    final generation = _batchGeneration;
    try {
      final start = _loadedCount;
      final end = (start + _pageSize).clamp(0, _allItems.length);
      final batch = _allItems.sublist(start, end);
      await _loadAspectRatios(batch);
      await _precacheBatch(batch);
      // 期间发生过重新排序：本批属于旧顺序，直接作废
      if (generation != _batchGeneration) return;
      // 宽高比与像素都已就绪，才允许 _loadMore 把这一批显示出来
      _loadedCount = end;
    } finally {
      _isPreloading = false;
    }
  }

  /// 滚动接近底部时：立即显示已预加载的视频，并预加载下一批
  void _loadMore() {
    if (_items.length >= _allItems.length) return;
    // 显示已预加载的视频（宽高比与像素都已就绪，无跳变、无卡顿）
    final newItems = _allItems.sublist(_items.length, _loadedCount);
    if (newItems.isNotEmpty) {
      setState(() {
        _items.addAll(newItems);
      });
    }
    // 预加载下一批
    unawaited(_preloadNextBatch());
  }

  /// 读取一批视频的宽高比，完成后一次性更新（避免频繁 setState）
  ///
  /// Android 端 MediaStore 已直接给出宽高比，只有未索引到尺寸的视频
  /// 才需要走文件解析，因此这里先过滤再解析。
  Future<void> _loadAspectRatios(List<VideoItem> batch) async {
    final pendingIndexes = <int>[];
    final pendingPaths = <String>[];
    for (var i = 0; i < batch.length; i++) {
      if (batch[i].aspectRatio == null) {
        pendingIndexes.add(i);
        pendingPaths.add(batch[i].path);
      }
    }
    if (pendingPaths.isEmpty) return;

    final ratios = await VideoScanService.readAspectRatios(pendingPaths);
    if (!mounted) return;
    setState(() {
      // 建立 路径→索引 映射，避免逐项 indexWhere 导致 O(n²)
      final allIndexByPath = <String, int>{};
      for (var i = 0; i < _allItems.length; i++) {
        allIndexByPath[_allItems[i].path] = i;
      }
      final itemIndexByPath = <String, int>{};
      for (var i = 0; i < _items.length; i++) {
        itemIndexByPath[_items[i].path] = i;
      }

      for (var k = 0; k < pendingPaths.length; k++) {
        final ratio = ratios[k];
        if (ratio == null) continue;
        final i = pendingIndexes[k];
        final item = batch[i];
        final updated = VideoItem(
          name: item.name,
          path: item.path,
          aspectRatio: ratio,
        );
        // 更新全部列表
        final allIndex = allIndexByPath[item.path];
        if (allIndex != null) _allItems[allIndex] = updated;
        // 更新显示列表
        final index = itemIndexByPath[item.path];
        if (index != null) _items[index] = updated;
        // 同步 batch 内的对象，保证调用方能拿到带宽高比的新对象
        batch[i] = updated;
      }
    });
  }

  /// 预生成一批视频的缩略图，填充缩略图缓存
  Future<void> _precacheBatch(List<VideoItem> batch) async {
    if (!mounted || batch.isEmpty) return;
    await MasonryVideoGrid.precacheAll(batch.map((e) => e.path).toList());
  }

  // ── 排序 ──
  /// 按当前排序方式排列 [_allItems]
  void _applySortToAllItems() {
    switch (_sortMode) {
      case _SortMode.byName:
        _allItems.sort((a, b) {
          final cmp = a.name.compareTo(b.name);
          return _nameAscending ? cmp : -cmp;
        });
        break;
      case _SortMode.byTime:
        _allItems.sort((a, b) {
          final cmp = _modifiedTimeOf(a).compareTo(_modifiedTimeOf(b));
          return _newestFirst ? -cmp : cmp;
        });
        break;
      case _SortMode.random:
        _allItems.shuffle();
        break;
    }
  }

  /// 读取文件修改时间；读取失败时按最早处理，保证排序结果稳定
  DateTime _modifiedTimeOf(VideoItem item) {
    try {
      return File(item.path).lastModifiedSync();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// 重新排序并重建首屏批次（顺序变化后，后续批次需按新顺序重新加载）
  void _resort() {
    setState(() {
      _batchGeneration++;
      _selectedIndex = null;
      _applySortToAllItems();
      _items = _allItems.take(_pageSize).toList();
      _loadedCount = _allItems.length.clamp(0, _pageSize);
    });
    unawaited(_bootstrapBatches());
  }

  /// 顺序：点击切到顺序模式；已在顺序模式时，再次点击在顺序/逆序间切换
  void _onSortByNamePressed() {
    if (_sortMode == _SortMode.byName) {
      _nameAscending = !_nameAscending;
    } else {
      _sortMode = _SortMode.byName;
    }
    _resort();
  }

  /// 最新：点击切到最新模式；已在最新模式时，再次点击在最新/最旧间切换
  void _onSortByTimePressed() {
    if (_sortMode == _SortMode.byTime) {
      _newestFirst = !_newestFirst;
    } else {
      _sortMode = _SortMode.byTime;
      _newestFirst = true;
    }
    _resort();
  }

  /// 随机：每次点击都重新打乱
  void _onSortRandomPressed() {
    _sortMode = _SortMode.random;
    _resort();
  }

  /// 排序按钮；当前生效的排序方式用强调色标识，图标体现方向
  Widget _buildSortButton({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      color: active ? const Color(0xFFe94560) : Colors.white70,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  // ── 单图操作 ──
  void _excludeVideo(String path) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.addExcludedPath(path);
    setState(() {
      _items.removeWhere((item) => item.path == path);
      _allItems.removeWhere((item) => item.path == path);
    });
    _showSnack(AppLocalizations.of(context).excluded);
  }

  /// 卡片右下角按钮的统一行为：按「删除行为」设置执行排除播放或实际删除
  void _applyDeleteAction(VideoItem item) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.deleteAction == DeleteAction.exclude) {
      _excludeVideo(item.path);
    } else {
      _deleteVideo(item);
    }
  }

  Future<void> _deleteVideo(VideoItem item) async {
    final ok = await MediaStoreService.deleteToTrash([item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    setState(() {
      _items.removeWhere((i) => i.path == item.path);
      _allItems.removeWhere((i) => i.path == item.path);
    });
    _showSnack(AppLocalizations.of(context).deletedToTrash);
  }

  /// 从瀑布流进入播放。
  ///
  /// 播放范围限定为当前文件夹：使用本次扫描到的全部视频（而不是仅已加载的
  /// 那一批），顺序按「播放顺序」设置排列，起点为被点中的那个视频。
  void _startPlaybackFrom(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    slideProvider.setVideos(_allItems.toList(), playOrder: settings.playOrder);
    slideProvider.sortByPlayOrder(settings.playOrder);
    // 排序后重新定位被点中的视频；理论上必然能找到，兜底回到第一个
    final startIndex = slideProvider.videos.indexWhere(
      (video) => video.path == item.path,
    );
    slideProvider.goToVideo(startIndex >= 0 ? startIndex : 0);
    slideProvider.startPlay();

    setState(() => _selectedIndex = null);
    Navigator.pushNamed(context, '/player');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // 卡片右下角按钮的图标/颜色/提示随「删除行为」设置变化，需要随设置重建
    final deleteExcludes =
        Provider.of<SettingsProvider>(context, listen: true).deleteAction ==
        DeleteAction.exclude;
    // 返回上一页时先退出全屏，避免带着无边框全屏窗口回到上一页
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) FullscreenService.instance.exit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            Platform.isAndroid
                ? _getLastPathSegment(widget.folderPath)
                : widget.folderPath,
            overflow: TextOverflow.ellipsis,
          ),
          centerTitle: true,
          backgroundColor: const Color(0xFF16213e),
          actions: [
            if (_items.isNotEmpty) ...[
              // 顺序/逆序：用一对方向相反的箭头表示升序/降序
              _buildSortButton(
                icon: _nameAscending
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
                tooltip: _nameAscending ? loc.sortSequential : loc.sortReverse,
                active: _sortMode == _SortMode.byName,
                onPressed: _onSortByNamePressed,
              ),
              // 最新/最旧：用一对方向相反的时钟图标表示时间倒序/正序
              _buildSortButton(
                icon: _newestFirst ? Icons.update : Icons.history,
                tooltip: _newestFirst ? loc.sortNewest : loc.sortOldest,
                active: _sortMode == _SortMode.byTime,
                onPressed: _onSortByTimePressed,
              ),
              // 随机（每次点击重新打乱）
              _buildSortButton(
                icon: Icons.shuffle,
                tooltip: loc.sortRandom,
                active: _sortMode == _SortMode.random,
                onPressed: _onSortRandomPressed,
              ),
            ],
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.movie_outlined, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(
                      loc.noVideosInFolder,
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ],
                ),
              )
            : MasonryVideoGrid(
                items: _items,
                selectedIndex: _selectedIndex,
                hasMore: _items.length < _allItems.length,
                onLoadMore: _loadMore,
                onTap: (index) {
                  // 桌面端悬停即可看到删除按钮，点按直接进入播放；
                  // 手机端没有悬停，第一次点按先显示删除按钮，再次点按才进入播放
                  final isMobile = Platform.isAndroid || Platform.isIOS;
                  if (!isMobile || _selectedIndex == index) {
                    _startPlaybackFrom(index);
                  } else {
                    setState(() {
                      _selectedIndex = index;
                    });
                  }
                },
                onLongPress: _startPlaybackFrom,
                onDelete: (index) {
                  _applyDeleteAction(_items[index]);
                  if (mounted) setState(() => _selectedIndex = null);
                },
                singleActionOverlay: true,
                singleActionIcon: deleteExcludes
                    ? Icons.block
                    : Icons.delete_outline,
                singleActionColor: deleteExcludes
                    ? Colors.orange
                    : Colors.redAccent,
                singleActionTooltip: deleteExcludes
                    ? loc.excludeFromPlay
                    : loc.deleteVideo,
              ),
      ),
    );
  }

  /// 提取路径的最后一级目录名（兼容 / 和 \ 分隔符）
  String _getLastPathSegment(String path) {
    var clean = path;
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastIndex = clean.lastIndexOf(RegExp(r'[/\\]'));
    return lastIndex >= 0 ? clean.substring(lastIndex + 1) : clean;
  }
}
