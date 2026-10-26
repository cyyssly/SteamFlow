import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/services/lan_client_service.dart';
import 'package:steam_flow/services/remote_copy_service.dart';
import 'package:steam_flow/widgets/browse_layout_icon.dart';
import 'package:steam_flow/widgets/masonry_video_grid.dart';
import 'package:steam_flow/widgets/sort_alphabet_icon.dart';
import 'package:steam_flow/main.dart';

/// 远端文件夹的排序方式
enum _RemoteSortAction {
  nameAsc,
  nameDesc,
  timeNewest,
  timeOldest,
  sizeLargest,
  sizeSmallest,
  random,
  newPreferred,
}

/// 远端共享文件夹的视频瀑布流。
class RemoteVideosScreen extends StatefulWidget {
  final LanDevice device;
  final String folderId;
  final String folderName;

  const RemoteVideosScreen({
    super.key,
    required this.device,
    required this.folderId,
    required this.folderName,
  });

  @override
  State<RemoteVideosScreen> createState() => _RemoteVideosScreenState();
}

class _RemoteVideosScreenState extends State<RemoteVideosScreen>
    with RouteAware {
  List<VideoItem> _videos = [];
  bool _loading = true;
  bool _failed = false;
  int? _selectedIndex;

  /// 正在复制的视频（键），用于避免重复触发
  String? _copyingKey;

  /// 当前排序方式（默认顺序）
  _RemoteSortAction _sortAction = _RemoteSortAction.nameAsc;

  /// 当前浏览格式；未单独设置过的共享文件夹跟随设置页默认值
  BrowseLayout _browseLayout = BrowseLayout.masonry;

  /// 随机排序的种子：同一次浏览固定不变，各页顺序才一致
  String _randomSeed = '';

  /// 首屏加载代次：快速切换排序时丢弃已过期的响应
  int _loadGeneration = 0;

  /// 已订阅路由事件的当前路由
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _restoreSortMode();
    _restoreBrowseLayout();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 进入页面时刷新一次能力，决定复制按钮是否可用
      Provider.of<LanProvider>(
        context,
        listen: false,
      ).refreshCapabilities(widget.device);
    });
  }

  /// 该共享文件夹的持久化键，与 [SharedFolderRef.key] 保持一致
  String get _sharedFolderKey => '${widget.device.id}/${widget.folderId}';

  /// 恢复上次使用的排序方式；用户未选择过时跟随设置页的播放顺序
  void _restoreSortMode() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final saved = settings.sharedSortFor(_sharedFolderKey);
    var restored = false;
    if (saved != null) {
      for (final action in _RemoteSortAction.values) {
        if (action.name == saved) {
          _sortAction = action;
          restored = true;
          break;
        }
      }
    }
    if (!restored) {
      _sortAction = _actionForPlayOrder(settings.playOrder);
    }
    if (_sortAction == _RemoteSortAction.random) {
      // 恢复随机排序时也要固定种子，否则逐页请求会得到不一致的顺序
      _randomSeed = DateTime.now().microsecondsSinceEpoch.toString();
    }
  }

  /// 恢复该共享文件夹上次使用的浏览格式；未单独设置时跟随设置页默认值
  void _restoreBrowseLayout() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _browseLayout =
        SettingsProvider.parseBrowseLayout(
          settings.sharedBrowseLayoutFor(_sharedFolderKey),
        ) ??
        settings.browseLayout;
  }

  /// 切换浏览格式，并记住到当前共享文件夹
  void _applyBrowseLayout(BrowseLayout layout) {
    if (layout == _browseLayout) return;
    setState(() {
      _browseLayout = layout;
      _selectedIndex = null;
    });
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).setSharedBrowseLayout(_sharedFolderKey, layout);
  }

  /// 设置页播放顺序 → 瀑布流排序方式的映射
  static _RemoteSortAction _actionForPlayOrder(PlayOrder order) {
    switch (order) {
      case PlayOrder.sequential:
        return _RemoteSortAction.nameAsc;
      case PlayOrder.reverseSequential:
        return _RemoteSortAction.nameDesc;
      case PlayOrder.newestFirst:
        return _RemoteSortAction.timeNewest;
      case PlayOrder.oldestFirst:
        return _RemoteSortAction.timeOldest;
      case PlayOrder.sizeLargest:
        return _RemoteSortAction.sizeLargest;
      case PlayOrder.sizeSmallest:
        return _RemoteSortAction.sizeSmallest;
      case PlayOrder.random:
        return _RemoteSortAction.random;
      case PlayOrder.newPreferred:
        return _RemoteSortAction.newPreferred;
    }
  }

  /// 当前排序对应的服务端参数
  String? get _sortKey {
    switch (_sortAction) {
      case _RemoteSortAction.nameAsc:
      case _RemoteSortAction.nameDesc:
        return 'name';
      case _RemoteSortAction.timeNewest:
      case _RemoteSortAction.timeOldest:
        return 'time';
      case _RemoteSortAction.sizeLargest:
      case _RemoteSortAction.sizeSmallest:
        return 'size';
      case _RemoteSortAction.random:
        return 'random';
      case _RemoteSortAction.newPreferred:
        // 新视频优先需要全量元数据在客户端加权随机，不使用服务端排序
        return null;
    }
  }

  String get _sortOrder {
    switch (_sortAction) {
      case _RemoteSortAction.nameAsc:
      case _RemoteSortAction.timeOldest:
      case _RemoteSortAction.sizeSmallest:
        return 'asc';
      case _RemoteSortAction.nameDesc:
      case _RemoteSortAction.timeNewest:
      case _RemoteSortAction.sizeLargest:
        return 'desc';
      case _RemoteSortAction.random:
      case _RemoteSortAction.newPreferred:
        return 'asc';
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _failed = false;
    });

    List<VideoItem>? videos;
    if (_sortAction == _RemoteSortAction.newPreferred) {
      final all = await LanClientService.instance.fetchAllVideos(
        widget.device,
        folderId: widget.folderId,
      );
      if (all != null) {
        videos = List<VideoItem>.of(all);
        SlideProvider.applyNewPreferredOrder(videos);
      }
    } else {
      videos = await LanClientService.instance.fetchAllVideos(
        widget.device,
        folderId: widget.folderId,
        sort: _sortKey,
        order: _sortOrder,
        seed: _sortAction == _RemoteSortAction.random ? _randomSeed : null,
      );
    }
    if (!mounted || generation != _loadGeneration) return;
    if (videos != null) {
      // 列表已从服务端重新拉取，本地“最近排除”提示不再需要
      Provider.of<LanProvider>(
        context,
        listen: false,
      ).clearRemoteExcluded(widget.device.id);
    }
    setState(() {
      _videos = videos ?? const [];
      _failed = videos == null;
      _loading = false;
    });
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

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// 从播放页返回时，远端排除过的视频立即从当前列表移除（保留滚动位置）
  @override
  void didPopNext() {
    Future.microtask(() {
      if (!mounted) return;
      final lan = Provider.of<LanProvider>(context, listen: false);
      final filtered = [
        for (final video in _videos)
          if (!lan.isRemoteExcluded(widget.device.id, video.remoteId ?? ''))
            video,
      ];
      if (filtered.length == _videos.length) {
        if (mounted) setState(() => _selectedIndex = null);
        return;
      }
      setState(() {
        _videos = filtered;
        _selectedIndex = null;
      });
    });
  }

  /// 应用菜单中选中的排序方式，并记住该共享文件夹的选择
  void _applySort(_RemoteSortAction action) {
    setState(() {
      _sortAction = action;
      _selectedIndex = null;
      if (action == _RemoteSortAction.random) {
        // 每次选择随机都换一个种子，保证同一次浏览的后续分页顺序一致
        _randomSeed = DateTime.now().microsecondsSinceEpoch.toString();
      }
    });
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).setSharedSort(_sharedFolderKey, action.name);
    _load();
  }

  bool _isSortActive(_RemoteSortAction action) => _sortAction == action;

  /// 各排序方式对应的图标；既用于菜单项，也用于标题栏显示当前选中项
  Widget _sortIcon(_RemoteSortAction action, Color color) {
    switch (action) {
      case _RemoteSortAction.nameAsc:
        return SortAlphabetIcon(ascending: true, color: color);
      case _RemoteSortAction.nameDesc:
        return SortAlphabetIcon(ascending: false, color: color);
      case _RemoteSortAction.timeNewest:
        return Icon(Icons.update, color: color);
      case _RemoteSortAction.timeOldest:
        return Icon(Icons.history, color: color);
      case _RemoteSortAction.sizeLargest:
        return Icon(Icons.south, color: color);
      case _RemoteSortAction.sizeSmallest:
        return Icon(Icons.north, color: color);
      case _RemoteSortAction.random:
        return Icon(Icons.shuffle, color: color);
      case _RemoteSortAction.newPreferred:
        return Icon(Icons.fiber_new, color: color);
    }
  }

  PopupMenuItem<_RemoteSortAction> _sortMenuItem({
    required _RemoteSortAction action,
    required String label,
  }) {
    final selected = _isSortActive(action);
    final color = selected ? const Color(0xFFe94560) : Colors.white70;
    return PopupMenuItem<_RemoteSortAction>(
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
    return PopupMenuButton<_RemoteSortAction>(
      tooltip: loc.sortBy,
      icon: _sortIcon(_sortAction, Colors.white70),
      onSelected: _applySort,
      itemBuilder: (context) => [
        _sortMenuItem(
          action: _RemoteSortAction.nameAsc,
          label: loc.sortSequential,
        ),
        _sortMenuItem(
          action: _RemoteSortAction.nameDesc,
          label: loc.sortReverse,
        ),
        _sortMenuItem(
          action: _RemoteSortAction.timeNewest,
          label: loc.sortNewest,
        ),
        _sortMenuItem(
          action: _RemoteSortAction.timeOldest,
          label: loc.sortOldest,
        ),
        _sortMenuItem(
          action: _RemoteSortAction.sizeLargest,
          label: loc.largestFirst,
        ),
        _sortMenuItem(
          action: _RemoteSortAction.sizeSmallest,
          label: loc.smallestFirst,
        ),
        _sortMenuItem(action: _RemoteSortAction.random, label: loc.sortRandom),
        _sortMenuItem(
          action: _RemoteSortAction.newPreferred,
          label: loc.newPreferred,
        ),
      ],
    );
  }

  /// 卡片短按：桌面端直接播放；手机端按「短按行为」设置执行播放或选中
  void _handleCardTap(int index) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) {
      _startPlayback(index);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.mobileTapAction == MobileTapAction.play ||
        _selectedIndex == index) {
      _startPlayback(index);
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
    _startPlayback(index);
  }

  /// 以当前共享文件夹为播放范围进入播放页，顺序沿用瀑布流当前排序。
  void _startPlayback(int index) {
    if (index < 0 || index >= _videos.length) return;
    final item = _videos[index];
    final slide = Provider.of<SlideProvider>(context, listen: false);

    slide.setVideos(List<VideoItem>.of(_videos), followListOrder: true);
    final startIndex = slide.videos.indexWhere(
      (video) => video.key == item.key,
    );
    slide.goToVideo(startIndex >= 0 ? startIndex : 0);
    slide.startPlay();

    setState(() => _selectedIndex = null);
    Navigator.pushNamed(context, '/player');
  }

  /// 复制远端视频到本地（支持进度、取消与断点续传）
  Future<void> _copyToLocal(VideoItem item) async {
    if (_copyingKey != null) return;
    final loc = AppLocalizations.of(context);
    final lan = Provider.of<LanProvider>(context, listen: false);
    if (!lan.capabilitiesFor(widget.device.id).copy) {
      _showSnack(loc.lanRemotePermissionDenied);
      return;
    }
    if (RemoteCopyService.isCopying) {
      _showSnack(loc.lanCopyBusy);
      return;
    }

    final destination = await RemoteCopyService.resolveDestination(context);
    if (destination == null || !mounted) return;

    setState(() => _copyingKey = item.key);
    final status = await RemoteCopyService.copyToLocal(
      context,
      item,
      destination,
    );
    if (!mounted) return;
    setState(() => _copyingKey = null);
    switch (status) {
      case RemoteCopyStatus.success:
        _showSnack(loc.lanCopied);
        break;
      case RemoteCopyStatus.cancelled:
        _showSnack(loc.lanCopyCancelled);
        break;
      case RemoteCopyStatus.busy:
        _showSnack(loc.lanCopyBusy);
        break;
      case RemoteCopyStatus.failed:
        _showSnack(loc.lanCopyFailed);
        break;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final settings = Provider.of<SettingsProvider>(context, listen: true);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName, overflow: TextOverflow.ellipsis),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        actions: [
          if (_videos.isNotEmpty) ...[
            IconButton(
              tooltip: loc.startPlay,
              icon: const Icon(Icons.play_arrow, color: Colors.white70),
              onPressed: () => _startPlayback(0),
            ),
            BrowseLayoutMenuButton(
              value: _browseLayout,
              onSelected: _applyBrowseLayout,
            ),
            _buildSortMenu(loc),
          ],
          IconButton(
            tooltip: loc.lanRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(loc.lanLoadFailed),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _load, child: Text(loc.lanRetry)),
                ],
              ),
            )
          : _videos.isEmpty
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
              items: _videos,
              fileListInfo: settings.fileListInfo,
              layout: _browseLayout,
              selectedIndex: _selectedIndex,
              onTap: _handleCardTap,
              onLongPress: _handleCardLongPress,
              onDelete: (index) => _copyToLocal(_videos[index]),
              singleActionOverlay: true,
              singleActionIcon: Icons.download,
              singleActionColor: Colors.white,
              singleActionTooltip: loc.lanCopyToLocal,
            ),
    );
  }
}
