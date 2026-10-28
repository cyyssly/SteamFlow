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
import 'package:steam_flow/utils/filename_compare.dart';
import 'package:steam_flow/widgets/browse_layout_icon.dart';
import 'package:steam_flow/widgets/masonry_video_grid.dart';
import 'package:steam_flow/widgets/sort_alphabet_icon.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/main.dart';

/// 瀑布流排序方式
enum _SortAction {
  nameAsc,
  nameDesc,
  timeNewest,
  timeOldest,
  sizeLargest,
  sizeSmallest,
  random,
  newPreferred,
}

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

class _FolderVideosScreenState extends State<FolderVideosScreen>
    with RouteAware {
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

  /// 当前排序方式（默认顺序）
  _SortAction _sortAction = _SortAction.nameAsc;

  /// 当前浏览格式；未单独设置过的文件夹跟随设置页默认值
  BrowseLayout _browseLayout = BrowseLayout.masonry;

  /// 批次代次：每次重新排序都自增，使跨越排序、尚在途中的旧批次作废，
  /// 避免把「旧顺序下的这一批已就绪」错误地记到新顺序的批次边界上。
  int _batchGeneration = 0;

  /// 已订阅路由事件的当前路由
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _restoreSortMode();
    _restoreBrowseLayout();
    _loadVideos();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
  }

  /// 恢复该文件夹上次使用的浏览格式；未单独设置时跟随设置页默认值
  void _restoreBrowseLayout() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _browseLayout =
        SettingsProvider.parseBrowseLayout(
          settings.localBrowseLayoutFor(widget.folderPath),
        ) ??
        settings.browseLayout;
  }

  /// 切换浏览格式，并记住到当前文件夹
  void _applyBrowseLayout(BrowseLayout layout) {
    if (layout == _browseLayout) return;
    setState(() {
      _browseLayout = layout;
      _selectedIndex = null;
    });
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).setLocalBrowseLayout(widget.folderPath, layout);
  }

  /// 恢复该文件夹上次使用的排序方式；用户未选择过时跟随设置页的播放顺序
  void _restoreSortMode() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final saved = settings.localSortFor(widget.folderPath);
    if (saved != null) {
      for (final action in _SortAction.values) {
        if (action.name == saved) {
          _sortAction = action;
          return;
        }
      }
    }
    _sortAction = _actionForPlayOrder(settings.playOrder);
  }

  /// 设置页播放顺序 → 瀑布流排序方式的映射
  static _SortAction _actionForPlayOrder(PlayOrder order) {
    switch (order) {
      case PlayOrder.sequential:
        return _SortAction.nameAsc;
      case PlayOrder.reverseSequential:
        return _SortAction.nameDesc;
      case PlayOrder.newestFirst:
        return _SortAction.timeNewest;
      case PlayOrder.oldestFirst:
        return _SortAction.timeOldest;
      case PlayOrder.sizeLargest:
        return _SortAction.sizeLargest;
      case PlayOrder.sizeSmallest:
        return _SortAction.sizeSmallest;
      case PlayOrder.random:
        return _SortAction.random;
      case PlayOrder.newPreferred:
        return _SortAction.newPreferred;
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      appRouteObserver.subscribe(this, route);
      _route = route;
    }
  }

  /// 从播放页返回时，排除/删除操作可能改变了文件集合，过滤后重建批次。
  @override
  void didPopNext() {
    unawaited(
      Future.microtask(() async {
        if (!mounted) return;
        await _refreshAfterReturn();
      }),
    );
  }

  Future<void> _refreshAfterReturn() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final excluded = {
      for (final path in settings.excludedPaths)
        Platform.isWindows ? path.toLowerCase() : path,
    };

    final filtered = <VideoItem>[];
    for (final item in _allItems) {
      final key = Platform.isWindows ? item.path.toLowerCase() : item.path;
      if (excluded.contains(key)) continue;
      // 逐个异步检查，避免大量文件时在 UI 线程做同步磁盘访问
      try {
        if (!await File(item.path).exists()) continue;
      } catch (_) {
        continue;
      }
      filtered.add(item);
    }
    if (!mounted) return;

    if (filtered.length == _allItems.length) {
      setState(() => _selectedIndex = null);
      return;
    }
    final loaded = _loadedCount.clamp(0, filtered.length);
    setState(() {
      _batchGeneration++;
      _selectedIndex = null;
      _allItems = filtered;
      _items = filtered.take(loaded).toList();
      _loadedCount = loaded;
    });
    unawaited(_bootstrapBatches());
  }

  /// 键盘快捷键：F11 切换全屏，ESC 返回文件夹列表
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，而播放页也注册了
  /// F11/ESC，因此这里必须确认本页位于最上层，否则同一次按键会被两页各处理
  /// 一次（先进全屏再退全屏，等于没反应）。
  /// 全屏切换只由 F11 负责，ESC 不再具备退出全屏功能。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      // 返回上一页；若当前处于全屏，由 build 中的 PopScope 统一恢复窗口
      Navigator.maybePop(context);
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

  /// 读取一批视频的宽高比与真实分辨率，完成后一次性更新（避免频繁 setState）
  ///
  /// Android 端 MediaStore 已直接给出宽高比与分辨率，只有未索引到尺寸的视频
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

    final infos = await VideoScanService.readSizes(pendingPaths);
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
        final info = infos[k];
        // 宽高比与分辨率都拿不到时跳过（保持原样）
        if (info.aspectRatio == null && info.width == null) continue;
        final i = pendingIndexes[k];
        final item = batch[i];
        final updated = VideoItem(
          name: item.name,
          path: item.path,
          aspectRatio: info.aspectRatio ?? item.aspectRatio,
          modifiedTime: item.modifiedTime,
          sizeBytes: item.sizeBytes,
          width: info.width ?? item.width,
          height: info.height ?? item.height,
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
    switch (_sortAction) {
      case _SortAction.nameAsc:
        _allItems.sort((a, b) => compareFileNames(a.name, b.name));
        break;
      case _SortAction.nameDesc:
        _allItems.sort((a, b) => compareFileNames(b.name, a.name));
        break;
      case _SortAction.timeNewest:
        _allItems.sort(
          (a, b) => _modifiedTimeOf(b).compareTo(_modifiedTimeOf(a)),
        );
        break;
      case _SortAction.timeOldest:
        _allItems.sort(
          (a, b) => _modifiedTimeOf(a).compareTo(_modifiedTimeOf(b)),
        );
        break;
      case _SortAction.sizeLargest:
        _allItems.sort((a, b) => _sizeOf(b).compareTo(_sizeOf(a)));
        break;
      case _SortAction.sizeSmallest:
        _allItems.sort((a, b) => _sizeOf(a).compareTo(_sizeOf(b)));
        break;
      case _SortAction.random:
        _allItems.shuffle();
        break;
      case _SortAction.newPreferred:
        SlideProvider.applyNewPreferredOrder(_allItems);
        break;
    }
  }

  /// 读取文件修改时间；优先用扫描时已带的时间，缺失时回退到文件系统
  DateTime _modifiedTimeOf(VideoItem item) {
    final known = item.modifiedTime;
    if (known != null) return known;
    try {
      return File(item.path).lastModifiedSync();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// 读取文件大小；优先用扫描时已带的值，缺失时回退到文件系统
  int _sizeOf(VideoItem item) {
    final known = item.sizeBytes;
    if (known != null) return known;
    try {
      return File(item.path).lengthSync();
    } catch (_) {
      return 0;
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

  /// 应用菜单中选中的排序方式，并记住该文件夹的选择
  void _applySort(_SortAction action) {
    _sortAction = action;
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).setLocalSort(widget.folderPath, action.name);
    _resort();
  }

  bool _isSortActive(_SortAction action) => _sortAction == action;

  /// 各排序方式对应的图标；既用于菜单项，也用于标题栏显示当前选中项
  Widget _sortIcon(_SortAction action, Color color) {
    switch (action) {
      case _SortAction.nameAsc:
        return SortAlphabetIcon(ascending: true, color: color);
      case _SortAction.nameDesc:
        return SortAlphabetIcon(ascending: false, color: color);
      case _SortAction.timeNewest:
        return Icon(Icons.update, color: color);
      case _SortAction.timeOldest:
        return Icon(Icons.history, color: color);
      case _SortAction.sizeLargest:
        return Icon(Icons.south, color: color);
      case _SortAction.sizeSmallest:
        return Icon(Icons.north, color: color);
      case _SortAction.random:
        return Icon(Icons.shuffle, color: color);
      case _SortAction.newPreferred:
        return Icon(Icons.fiber_new, color: color);
    }
  }

  PopupMenuItem<_SortAction> _sortMenuItem({
    required _SortAction action,
    required String label,
  }) {
    final selected = _isSortActive(action);
    final color = selected ? const Color(0xFFe94560) : Colors.white70;
    return PopupMenuItem<_SortAction>(
      value: action,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Center(child: _sortIcon(action, color)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          if (selected) Icon(Icons.check, color: color, size: 18),
        ],
      ),
    );
  }

  /// 排序入口：按钮直接显示当前排序的图标，点击弹出全部排序方式
  Widget _buildSortMenu(AppLocalizations loc) {
    return PopupMenuButton<_SortAction>(
      tooltip: loc.sortBy,
      icon: _sortIcon(_sortAction, Colors.white70),
      onSelected: _applySort,
      itemBuilder: (context) => [
        _sortMenuItem(action: _SortAction.nameAsc, label: loc.sortSequential),
        _sortMenuItem(action: _SortAction.nameDesc, label: loc.sortReverse),
        _sortMenuItem(action: _SortAction.timeNewest, label: loc.sortNewest),
        _sortMenuItem(action: _SortAction.timeOldest, label: loc.sortOldest),
        _sortMenuItem(action: _SortAction.sizeLargest, label: loc.largestFirst),
        _sortMenuItem(
          action: _SortAction.sizeSmallest,
          label: loc.smallestFirst,
        ),
        _sortMenuItem(action: _SortAction.random, label: loc.sortRandom),
        _sortMenuItem(
          action: _SortAction.newPreferred,
          label: loc.newPreferred,
        ),
      ],
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

  /// 卡片短按：桌面端直接播放；手机端按「短按行为」设置执行播放或选中
  void _handleCardTap(int index) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) {
      _startPlaybackFrom(index);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.mobileTapAction == MobileTapAction.play ||
        _selectedIndex == index) {
      _startPlaybackFrom(index);
    } else {
      setState(() => _selectedIndex = index);
    }
  }

  /// 长按：手机端「播放」模式下用于选中，其余情况直接播放
  void _handleCardLongPress(int index) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (isMobile && settings.mobileTapAction == MobileTapAction.play) {
      setState(() => _selectedIndex = index);
      return;
    }
    _startPlaybackFrom(index);
  }

  /// 从瀑布流进入播放。
  ///
  /// 播放范围限定为当前文件夹：使用本次扫描到的全部视频（而不是仅已加载的
  /// 那一批），顺序沿用瀑布流当前的排序，起点为被点中的那个视频。
  void _startPlaybackFrom(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    slideProvider.setVideos(_allItems.toList(), followListOrder: true);
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
    final settings = Provider.of<SettingsProvider>(context, listen: true);
    final deleteExcludes = settings.deleteAction == DeleteAction.exclude;
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
              IconButton(
                tooltip: loc.startPlay,
                icon: const Icon(Icons.play_arrow, color: Colors.white70),
                onPressed: () => _startPlaybackFrom(0),
              ),
              BrowseLayoutMenuButton(
                value: _browseLayout,
                onSelected: _applyBrowseLayout,
              ),
              _buildSortMenu(loc),
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
                    const Icon(
                      Icons.movie_outlined,
                      size: 64,
                      color: Colors.grey,
                    ),
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
                fileListInfo: settings.fileListInfo,
                layout: _browseLayout,
                selectedIndex: _selectedIndex,
                hasMore: _items.length < _allItems.length,
                onLoadMore: _loadMore,
                onTap: _handleCardTap,
                onLongPress: _handleCardLongPress,
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
