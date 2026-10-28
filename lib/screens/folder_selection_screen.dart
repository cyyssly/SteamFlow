import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/screens/excluded_videos_screen.dart';
import 'package:steam_flow/screens/folder_videos_screen.dart';
import 'package:steam_flow/screens/remote_browser_screen.dart';
import 'package:steam_flow/screens/remote_videos_screen.dart';
import 'package:steam_flow/services/directory_picker_service.dart';
import 'package:steam_flow/utils/filename_compare.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_formats.dart';
import 'package:steam_flow/services/video_scan_service.dart';
import 'package:steam_flow/services/video_thumbnail_service.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/main.dart';

class FolderSelectionScreen extends StatefulWidget {
  const FolderSelectionScreen({super.key});

  @override
  State<FolderSelectionScreen> createState() => _FolderSelectionScreenState();
}

class _FolderSelectionScreenState extends State<FolderSelectionScreen>
    with RouteAware {
  bool _isScanning = false;

  // 缓存每个文件夹的统计信息
  final Map<String, Map<String, int>> _folderStats = {};
  // 跟踪正在计数的文件夹
  final Set<String> _scanningFolders = {};

  /// 正在为该文件夹准备播放（扫描中），用于禁用其播放按钮并显示进度
  final Set<String> _playingFolders = {};

  /// 正在准备的共享文件夹（键），用于禁用播放按钮并显示进度
  final Set<String> _playingShared = {};

  /// 正在重连的共享文件夹（键），用于禁用重连按钮并显示进度
  final Set<String> _reconnectingShared = {};

  /// 是否正在添加文件夹（含原生对话框弹出期间），用于防止重复触发
  bool _isAddingFolder = false;

  /// 是否正在添加共享源（含设备选择/手动输入期间），用于防止重复触发
  bool _isAddingShareSource = false;

  /// “已排除的文件”分组的 Key 前缀
  static const String _excludedGroupKeyPrefix = 'excluded-group-';

  Future<void> _addFolder() async {
    // 防止重复触发（例如快速双击“添加文件夹”按钮）并发打开原生对话框。
    // Windows 原生目录对话框不允许并发打开，否则会触发 Shell 访问冲突，
    // 导致进程直接退出（Dart 层无法捕获）。
    if (_isAddingFolder) return;
    _isAddingFolder = true;
    try {
      await _addFolderImpl();
    } finally {
      _isAddingFolder = false;
    }
  }

  Future<void> _addFolderImpl() async {
    if (Platform.isAndroid) {
      // Android 端使用 MediaStore 读取相册列表
      final hasPermission = await MediaStoreService.requestStoragePermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).needPermissionToRead),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final albums = await MediaStoreService.getVideoAlbums();
      if (albums.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).msgNoAlbumsFound),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      // 弹出相册多选对话框
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      final currentFolderPaths = slideProvider.folderPaths.toSet();
      final selectedAlbums = await showDialog<List<AlbumInfo>>(
        context: context,
        builder: (context) {
          // 已选中的相册默认勾选
          final selected = <bool>[
            for (final album in albums) currentFolderPaths.contains(album.path),
          ];
          return AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: Text(
              AppLocalizations.of(context).selectAlbumTitle,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            content: SizedBox(
              width: double.maxFinite,
              // 限制最大高度，确保相册列表可以滚动
              height: MediaQuery.of(context).size.height * 0.6,
              child: StatefulBuilder(
                builder: (context, setDialogState) => ListView.builder(
                  shrinkWrap: true,
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    final isChecked = selected[index];
                    return CheckboxListTile(
                      value: isChecked,
                      onChanged: (value) {
                        setDialogState(() {
                          selected[index] = value ?? false;
                        });
                      },
                      activeColor: const Color(0xFFe94560),
                      checkColor: Colors.white,
                      secondary: _albumThumbnail(
                        thumbnailPath: album.thumbnailPath,
                        albumPath: album.path,
                      ),
                      title: Text(
                        album.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        AppLocalizations.of(
                          context,
                        ).videosCount(album.videoCount),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  AppLocalizations.of(context).cancel,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () {
                  final chosen = <AlbumInfo>[];
                  for (var i = 0; i < albums.length; i++) {
                    if (selected[i]) chosen.add(albums[i]);
                  }
                  Navigator.pop(context, chosen.isEmpty ? null : chosen);
                },
                child: Text(
                  AppLocalizations.of(context).confirm,
                  style: const TextStyle(
                    color: Color(0xFFe94560),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
      );

      if (selectedAlbums != null && selectedAlbums.isNotEmpty) {
        if (!mounted) return;
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        final settingsProvider = Provider.of<SettingsProvider>(
          context,
          listen: false,
        );
        for (final album in selectedAlbums) {
          slideProvider.addFolderPath(album.path);
        }
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        // 计算新添加相册的统计信息
        for (final album in selectedAlbums) {
          _countFolderVideos(album.path);
        }
      }
    } else {
      // 桌面端使用原生目录选择对话框（带互斥保护，避免重复弹窗导致原生崩溃）
      final result = await DirectoryPickerService.pickDirectory();
      if (result != null) {
        if (!mounted) return;
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        final settingsProvider = Provider.of<SettingsProvider>(
          context,
          listen: false,
        );
        slideProvider.addFolderPath(result);
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        // 计算新添加文件夹的统计信息
        _countFolderVideos(result);
      }
    }
  }

  /// 打开“添加共享源”：先选择设备，再进入该设备的共享文件夹列表勾选
  Future<void> _addShareSource() async {
    if (_isAddingShareSource) return;
    _isAddingShareSource = true;
    try {
      final lan = Provider.of<LanProvider>(context, listen: false);
      await lan.refresh();
      if (!mounted) return;

      final pick = await showDialog<_ShareSourcePick>(
        context: context,
        builder: (dialogContext) {
          final loc = AppLocalizations.of(dialogContext);
          return AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: Text(
              loc.addShareSource,
              style: const TextStyle(fontSize: 18),
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(dialogContext).size.height * 0.6,
              child: Consumer<LanProvider>(
                builder: (context, lan, _) => ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.add_link),
                      title: Text(loc.lanManualAdd),
                      subtitle: Text(loc.lanManualHint),
                      onTap: () => Navigator.pop(
                        dialogContext,
                        const _ShareSourcePick(null),
                      ),
                    ),
                    const Divider(height: 1),
                    if (lan.devices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            loc.lanNoDevices,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      for (final device in lan.devices)
                        ListTile(
                          leading: const Icon(
                            Icons.devices,
                            color: Color(0xFF00b894),
                          ),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.address} · '
                            '${loc.lanSharedFoldersCount(device.folderCount)}',
                          ),
                          onTap: () => Navigator.pop(
                            dialogContext,
                            _ShareSourcePick(device),
                          ),
                        ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  AppLocalizations.of(dialogContext).lanCancel,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          );
        },
      );
      if (pick == null || !mounted) return;

      var device = pick.device;
      if (device == null) {
        final input = await _promptManualAddress();
        if (input == null || !mounted) return;
        device = await lan.addManualDevice(input);
        if (device == null) {
          if (!mounted) return;
          final loc = AppLocalizations.of(context);
          _showSnack(
            lan.error == LanError.selfDevice
                ? loc.lanSelfDevice
                : loc.lanInvalidAddress,
          );
          return;
        }
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              RemoteBrowserScreen(device: device!, selectMode: true),
        ),
      );
    } finally {
      _isAddingShareSource = false;
    }
  }

  Future<String?> _promptManualAddress() async {
    final loc = AppLocalizations.of(context);
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: Text(loc.lanManualAdd),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: loc.lanManualHint),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(loc.lanCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(loc.lanAdd),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.trim().isEmpty) return null;
    return input;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  /// 计算文件夹中的视频数量和子文件夹数量
  Future<void> _countFolderVideos(String folderPath) async {
    if (_scanningFolders.contains(folderPath)) return;

    setState(() {
      _scanningFolders.add(folderPath);
    });

    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    try {
      int videoCount = 0;
      int subfolderCount = 0;

      if (Platform.isAndroid) {
        // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
        final videos = await MediaStoreService.getFolderVideos(folderPath);
        for (final item in videos) {
          if (isSupportedVideoPath(item.path)) videoCount++;
        }
      } else if (settingsProvider.recursiveScan) {
        final dir = Directory(folderPath);
        await for (var entity in dir.list(recursive: true)) {
          if (entity is File) {
            if (isSupportedVideoPath(entity.path)) videoCount++;
          } else if (entity is Directory) {
            subfolderCount++;
          }
        }
      } else {
        final dir = Directory(folderPath);
        final entities = await dir.list().toList();
        for (var entity in entities) {
          if (entity is File && isSupportedVideoPath(entity.path)) videoCount++;
        }
      }

      if (!mounted) return;
      setState(() {
        _folderStats[folderPath] = {
          'videoCount': videoCount,
          'subfolderCount': subfolderCount,
        };
        _scanningFolders.remove(folderPath);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _folderStats[folderPath] = {'videoCount': 0, 'subfolderCount': 0};
        _scanningFolders.remove(folderPath);
      });
    }
  }

  /// 提取路径的最后一级目录名（兼容 / 和 \ 分隔符）
  String _getLastPathSegment(String path) {
    // 去掉末尾的分隔符
    var clean = path;
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final lastIndex = clean.lastIndexOf(RegExp(r'[/\\]'));
    return lastIndex >= 0 ? clean.substring(lastIndex + 1) : clean;
  }

  /// 构建文件夹统计信息的 widget
  Widget _buildFolderStats(String folderPath) {
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (_scanningFolders.contains(folderPath)) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final stats = _folderStats[folderPath];
    if (stats == null) {
      return const SizedBox.shrink();
    }

    final videoCount = stats['videoCount'] ?? 0;
    final subfolderCount = stats['subfolderCount'] ?? 0;

    String countText;
    if (settingsProvider.recursiveScan) {
      countText = AppLocalizations.of(
        context,
      ).folderContentCount(subfolderCount, videoCount);
    } else {
      countText = AppLocalizations.of(context).filesCount(videoCount);
    }

    return Text(
      countText,
      style: const TextStyle(fontSize: 12, color: Colors.grey),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  void _removeFolder(String path) {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    slideProvider.removeFolderPath(path);
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 清除缓存的统计信息
    setState(() {
      _folderStats.remove(path);
      _scanningFolders.remove(path);
    });
  }

  /// 直接播放某个已选文件夹：以该文件夹为播放范围进入播放
  Future<void> _playFolder(String path) async {
    if (_playingFolders.contains(path)) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    setState(() {
      _playingFolders.add(path);
    });

    try {
      final videos = await _scanFolder(path, settingsProvider);
      if (!mounted) return;
      if (videos.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).msgNoVideos),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }

      // 与瀑布流页一致：范围限定为该文件夹，顺序按「播放顺序」设置
      slideProvider.setVideos(videos, playOrder: settingsProvider.playOrder);
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);
      slideProvider.goToVideo(0);
      slideProvider.startPlay();

      if (!mounted) return;
      Navigator.pushNamed(context, '/player');
    } finally {
      if (mounted) {
        setState(() {
          _playingFolders.remove(path);
        });
      }
    }
  }

  /// 直接播放某个共享文件夹：范围限定为该远端文件夹
  Future<void> _playSharedFolder(SharedFolderRef ref) async {
    if (_playingShared.contains(ref.key)) return;
    final lan = Provider.of<LanProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slide = Provider.of<SlideProvider>(context, listen: false);

    setState(() => _playingShared.add(ref.key));
    try {
      final videos = await lan.loadSharedFolderVideos(ref);
      if (!mounted) return;
      if (videos == null || videos.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).lanLoadFailed),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      slide.setVideos(videos, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToVideo(0);
      slide.startPlay();
      if (mounted) Navigator.pushNamed(context, '/player');
    } finally {
      if (mounted) {
        setState(() => _playingShared.remove(ref.key));
      }
    }
  }

  /// 重新连接共享源（离线时点击条目或“重新连接全部”）
  Future<void> _reconnectShared(List<SharedFolderRef> refs) async {
    if (refs.isEmpty) return;
    final lan = Provider.of<LanProvider>(context, listen: false);
    setState(() {
      for (final ref in refs) {
        _reconnectingShared.add(ref.key);
      }
    });
    try {
      // 逐个重连并收集结果：refreshSharedFolder 会同步最新的文件夹信息与封面，
      // 返回 false 表示设备离线或对方已不再共享该文件夹。
      final results = await Future.wait([
        for (final ref in refs) lan.refreshSharedFolder(ref),
      ]);
      if (!mounted) return;
      if (results.any((ok) => !ok)) {
        _showSnack(AppLocalizations.of(context).lanReconnectFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          for (final ref in refs) {
            _reconnectingShared.remove(ref.key);
          }
        });
      }
    }
  }

  /// 播放全部本地文件夹
  Future<void> _playLocalSection() async {
    if (_isScanning) return;
    final slide = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (slide.folderPaths.isEmpty) return;

    setState(() => _isScanning = true);
    try {
      final unique = <String, VideoItem>{};
      for (final path in slide.folderPaths) {
        final videos = await _scanFolder(path, settings);
        for (final video in videos) {
          unique.putIfAbsent(video.key, () => video);
        }
      }
      if (!mounted) return;
      if (unique.isEmpty) {
        _showSnack(AppLocalizations.of(context).msgNoVideos);
        return;
      }
      final videos = unique.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));
      slide.setVideos(videos, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToVideo(0);
      slide.startPlay();
      Navigator.pushNamed(context, '/player');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  /// 播放全部共享文件夹（离线设备自动跳过）
  Future<void> _playSharedSection() async {
    if (_isScanning) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final slide = Provider.of<SlideProvider>(context, listen: false);
    final refs = settings.sharedFolders;
    if (refs.isEmpty) return;

    setState(() => _isScanning = true);
    try {
      final unique = <String, VideoItem>{};
      for (final ref in refs) {
        if (!lan.isDeviceReachable(ref.deviceId)) continue;
        final videos = await lan.loadSharedFolderVideos(ref);
        if (videos == null) continue;
        for (final video in videos) {
          unique.putIfAbsent(video.key, () => video);
        }
      }
      if (!mounted) return;
      if (unique.isEmpty) {
        _showSnack(AppLocalizations.of(context).lanLoadFailed);
        return;
      }
      final videos = unique.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));
      slide.setVideos(videos, playOrder: settings.playOrder);
      slide.sortByPlayOrder(settings.playOrder);
      slide.goToVideo(0);
      slide.startPlay();
      Navigator.pushNamed(context, '/player');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  /// 统一的文件夹条目布局：固定 88dp 行高 + 内容垂直居中。
  ///
  /// [ListTile] 的标题/副标题按 Material 三行规格从顶部固定偏移排版，
  /// 内容不足三行时会明显偏上；这里改用 Row 自行布局，保证缩略图、
  /// 文本块与操作按钮始终在行内居中，三类条目的高度与对齐完全一致。
  Widget _folderRow({
    required Key key,
    required Widget leading,
    required String title,
    required Widget subtitle,
    required List<Widget> actions,
    Color? titleColor,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      key: key,
      height: 88,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: Platform.isAndroid ? 8 : 16,
            right: Platform.isAndroid ? 0 : 4,
          ),
          child: Row(
            children: [
              leading,
              SizedBox(width: Platform.isAndroid ? 8 : 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 14, color: titleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    subtitle,
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  /// 行内操作按钮：移动端压缩内边距与占位宽度，桌面端保持默认尺寸
  Widget _actionButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    final compact = Platform.isAndroid;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: compact ? EdgeInsets.zero : null,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 36, height: 40)
          : null,
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
    );
  }

  /// 分区标题：默认标题靠左、动作靠右；[actionsInline] 时标题与动作紧挨排列
  Widget _buildSectionHeader({
    required String title,
    required List<Widget> actions,
    bool actionsInline = false,
  }) {
    final titleWidget = Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(4, 8, Platform.isAndroid ? 0 : 4, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: Platform.isAndroid ? 40 : 48),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (actionsInline) ...[
              titleWidget,
              ...actions,
            ] else ...[
              Expanded(child: titleWidget),
              ...actions,
            ],
          ],
        ),
      ),
    );
  }

  /// 本机已选文件夹条目
  Widget _buildLocalFolderTile(String path) {
    final loc = AppLocalizations.of(context);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final ip = lan.localAddresses.isNotEmpty
        ? lan.localAddresses.first
        : '127.0.0.1';
    return _folderRow(
      // 使用稳定的 Key 绑定到文件夹路径，避免 ListView 按位置复用 State，
      // 导致缩略图组件残留上一个位置的视频
      key: ValueKey('folder-$path'),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: _ThumbnailVideo(
            // 排除列表变化时重建，避免沿用排除前缓存的封面
            key: ValueKey('thumb-$path-${settings.excludedPaths.length}'),
            thumbnailPath: null,
            albumPath: path,
          ),
        ),
      ),
      title: Platform.isAndroid ? _getLastPathSegment(path) : path,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildFolderStats(path),
          const SizedBox(height: 2),
          Text(
            '${settings.deviceName} · $ip',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        _actionButton(
          tooltip: loc.playFolder,
          icon: _playingFolders.contains(path)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_circle_outline, color: Colors.green),
          onPressed: _playingFolders.contains(path)
              ? null
              : () => _playFolder(path),
        ),
        _actionButton(
          tooltip: loc.removeFromManage,
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          onPressed: () => _removeFolder(path),
        ),
      ],
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FolderVideosScreen(folderPath: path),
          ),
        );
      },
    );
  }

  /// 共享文件夹无封面或离线时显示的文件夹图标
  Widget _sharedFolderIcon(bool online) {
    return Icon(
      Icons.folder_shared,
      size: 30,
      color: online ? const Color(0xFF00b894) : Colors.grey,
    );
  }

  /// 共享文件夹条目：离线时整体灰显，仅显示重连与移除
  Widget _buildSharedFolderTile(SharedFolderRef ref, LanProvider lan) {
    final loc = AppLocalizations.of(context);
    final online = lan.isDeviceReachable(ref.deviceId);
    final device = lan.deviceById(ref.deviceId);
    final deviceName = device?.name ?? ref.deviceName;
    final address = device?.address ?? ref.address;
    final coverFile = lan.coverFileFor(ref.key);
    final coverUrl = lan.coverUrlFor(ref.key);
    return _folderRow(
      key: ValueKey('shared-${ref.key}'),
      leading: SizedBox(
        width: 56,
        height: 56,
        child: coverFile != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(coverFile),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _sharedFolderIcon(online),
                ),
              )
            : coverUrl == null || coverUrl.isEmpty
            ? _sharedFolderIcon(online)
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  frameBuilder: (context, child, frame, loaded) {
                    if (loaded || frame != null) return child;
                    return _sharedFolderIcon(online);
                  },
                  errorBuilder: (_, _, _) => _sharedFolderIcon(online),
                ),
              ),
      ),
      title: ref.folderName,
      titleColor: online ? Colors.white : Colors.grey,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            loc.lanVideoCount(ref.videoCount),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '$deviceName · $address',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        if (!online)
          _actionButton(
            tooltip: loc.lanReconnectFolder,
            icon: _reconnectingShared.contains(ref.key)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _reconnectingShared.contains(ref.key)
                ? null
                : () => _reconnectShared([ref]),
          ),
        if (online)
          _actionButton(
            tooltip: loc.playFolder,
            icon: _playingShared.contains(ref.key)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_outline, color: Colors.green),
            onPressed: _playingShared.contains(ref.key)
                ? null
                : () => _playSharedFolder(ref),
          ),
        _actionButton(
          tooltip: loc.removeFromManage,
          icon: const Icon(Icons.remove_circle_outline, color: Colors.orange),
          onPressed: () => Provider.of<SettingsProvider>(
            context,
            listen: false,
          ).removeSharedFolder(ref.key),
        ),
      ],
      onTap: () {
        if (!online) {
          _reconnectShared([ref]);
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RemoteVideosScreen(
              device: lan.resolveDevice(ref),
              folderId: ref.folderId,
              folderName: ref.folderName,
            ),
          ),
        );
      },
    );
  }

  /// 构建“已排除文件”分组：按所在文件夹聚合，每个文件夹一行
  List<_ExcludedGroup> _buildExcludedGroups(SettingsProvider settings) {
    // 按父目录归组，并忽略应用外已被移走的文件
    final groups = <String, List<String>>{};
    final seen = <String>{};
    for (final path in settings.excludedPaths) {
      if (!File(path).existsSync()) continue;
      // 同一视频可能因历史数据被重复记录，只统计一次
      if (!seen.add(path)) continue;
      final parent = _normalizeFolderPath(File(path).parent.path);
      // 手机端只按最后一级目录名归组：同名目录即使路径不同也视为同一目录，
      // 避免出现两行同名但内容不同的分组
      final key = Platform.isAndroid ? _getLastPathSegment(parent) : parent;
      groups.putIfAbsent(key, () => []).add(path);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final entry in entries) _ExcludedGroup(entry.key, entry.value),
    ];
  }

  /// 规范化目录路径，避免同一目录因末尾分隔符差异被拆成两组
  String _normalizeFolderPath(String path) {
    if (path.isEmpty) return path;
    var clean = path;
    while (clean.length > 1 && (clean.endsWith('/') || clean.endsWith('\\'))) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  /// “已排除文件”分区标题（右侧提供恢复全部）
  Widget _buildExcludedHeader(List<_ExcludedGroup> groups) {
    final loc = AppLocalizations.of(context);
    final allPaths = [for (final group in groups) ...group.paths];
    return KeyedSubtree(
      key: const ValueKey('excluded-header'),
      child: _buildSectionHeader(
        title: loc.excludeFolderVirtual,
        actionsInline: true,
        actions: [
          _actionButton(
            tooltip: loc.restoreAll,
            icon: const Icon(Icons.undo, color: Colors.greenAccent),
            onPressed: () => _restoreExcludedGroup(allPaths),
          ),
        ],
      ),
    );
  }

  /// 单个文件夹的已排除文件条目
  ///
  /// [group.name] 即界面显示的分组名称（手机端为目录名，桌面端为完整路径）。
  Widget _buildExcludedGroupTile(_ExcludedGroup group) {
    final loc = AppLocalizations.of(context);
    final firstPath = group.paths.first;
    return _folderRow(
      key: ValueKey('$_excludedGroupKeyPrefix${group.name}'),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: _ThumbnailVideo(
            key: ValueKey('thumb-excluded-$firstPath'),
            thumbnailPath: firstPath,
            albumPath: firstPath,
          ),
        ),
      ),
      title: group.name,
      subtitle: Text(
        loc.filesCount(group.paths.length),
        style: const TextStyle(fontSize: 12, color: Colors.grey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        _actionButton(
          tooltip: loc.restoreFiles,
          icon: const Icon(Icons.undo, color: Colors.greenAccent),
          onPressed: () => _restoreExcludedGroup(group.paths),
        ),
        _actionButton(
          tooltip: loc.deleteFiles,
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: () => _deleteExcludedGroup(group.paths),
        ),
      ],
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ExcludedVideosScreen(
              folderName: group.name,
              paths: group.paths,
            ),
          ),
        );
      },
    );
  }

  /// 恢复某个文件夹下全部已排除视频
  void _restoreExcludedGroup(List<String> paths) {
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).removeExcludedPaths(paths);
  }

  /// 删除某个文件夹下全部已排除视频（移入回收站）
  Future<void> _deleteExcludedGroup(List<String> paths) async {
    final loc = AppLocalizations.of(context);
    final ok = await MediaStoreService.deleteToTrash(paths);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.deleteFailed), backgroundColor: Colors.red),
      );
      return;
    }
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).removeExcludedPaths(paths);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(loc.deletedAllToTrash)));
  }

  Future<void> _scanVideos() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    final lanProvider = Provider.of<LanProvider>(context, listen: false);
    final sharedRefs = settingsProvider.sharedFolders;

    if (slideProvider.folderPaths.isEmpty && sharedRefs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgAddFolderFirst),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() {
      _isScanning = true;
    });

    try {
      // 使用 Map 进行去重（本机用路径、远端用设备+文件夹+相对路径）
      final uniqueVideos = <String, VideoItem>{};
      bool hasStartedPlaying = false;
      int lastUpdateCount = 0;

      Future<void> collect(List<VideoItem> videos) async {
        for (final video in videos) {
          if (!uniqueVideos.containsKey(video.key)) {
            uniqueVideos[video.key] = video;
          }

          // 每收集到10个新视频就更新一次列表（播放中）
          if (hasStartedPlaying &&
              uniqueVideos.length - lastUpdateCount >= 10) {
            final newVideos = uniqueVideos.values.toList()
              ..sort((a, b) => compareFileNames(a.name, b.name));
            slideProvider.setVideos(newVideos);
            lastUpdateCount = uniqueVideos.length;
          }
        }

        // 如果已经收集到足够的视频且还未开始播放，则立即开始
        if (!hasStartedPlaying && uniqueVideos.length >= 10) {
          await _startPlaybackEarly(
            uniqueVideos.values.toList(),
            slideProvider,
            settingsProvider,
          );
          hasStartedPlaying = true;
          lastUpdateCount = uniqueVideos.length;
        }
      }

      // 逐个扫描本机文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final videos = await _scanFolder(folderPath, settingsProvider);
        await collect(videos);
      }

      // 再拉取已添加的共享文件夹；离线或读取失败的直接跳过
      for (final ref in sharedRefs) {
        final videos = await lanProvider.loadSharedFolderVideos(ref);
        if (videos == null) continue;
        await collect(videos);
      }

      // 按文件名排序
      final sortedVideos = uniqueVideos.values.toList()
        ..sort((a, b) => compareFileNames(a.name, b.name));

      if (sortedVideos.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).msgNoVideos),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        setState(() {
          _isScanning = false;
        });
        return;
      }

      if (!hasStartedPlaying) {
        // 如果视频少于10个，直接设置并返回
        slideProvider.setVideos(sortedVideos);
        settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).msgScanComplete(sortedVideos.length),
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );

        if (!mounted) return;
        Navigator.pop(context);
      } else {
        // 已经在播放中，更新完整列表
        if (sortedVideos.length != lastUpdateCount) {
          slideProvider.setVideos(sortedVideos);
          settingsProvider.setLastFolderPaths(slideProvider.folderPaths);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgScanFailed(e)),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _startPlaybackEarly(
    List<VideoItem> videos,
    SlideProvider slideProvider,
    SettingsProvider settingsProvider,
  ) async {
    // 对已收集的视频进行排序
    final sortedVideos = videos.toList()
      ..sort((a, b) => compareFileNames(a.name, b.name));

    slideProvider.setVideos(sortedVideos);
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 开始播放
    slideProvider.goToVideo(0);
    slideProvider.startPlay();

    if (mounted) {
      Navigator.pushNamed(context, '/player');
    }
  }

  Future<List<VideoItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) => VideoScanService.scanFolder(folderPath, settings);

  bool? _previousRecursiveScan;

  /// 断线共享文件夹的自动重连定时器与已尝试次数
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// 已订阅路由事件的当前路由
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    // 注册全局键盘监听：ESC 返回主界面
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    // 页面初始化时，对已有的文件夹触发统计计算
    Future.microtask(() {
      if (!mounted) return;
      _refreshStats();
      _probeSharedDevices();
    });
  }

  /// 重新统计所有已选文件夹与已排除文件的数量
  Future<void> _refreshStats() async {
    if (!mounted) return;
    // 先剔除磁盘上已不存在的文件夹（在应用外被删除）
    await _pruneMissingFolders();
    if (!mounted) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    setState(() {
      _folderStats.clear();
    });
    for (final path in slideProvider.folderPaths) {
      _countFolderVideos(path);
    }
  }

  /// 移除磁盘上已经不存在的文件夹。
  ///
  /// 与「存在但视频数量为 0」区分开：只要目录仍在就保留，由用户自行决定是否移除；
  /// 目录已被删除时直接从列表与设置中移除。判断失败（如网络盘权限受限）时保留，
  /// 避免误删用户的文件夹。
  Future<void> _pruneMissingFolders() async {
    if (!mounted) return;
    // Android 的“文件夹”是 MediaStore 相册，保存的是代表性视频文件路径而非目录路径，
    // 用 Directory.exists() 判断会把所有相册误删，因此移动端不做剔除。
    if (Platform.isAndroid) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    if (slideProvider.folderPaths.isEmpty) return;

    final missing = <String>[];
    for (final path in List<String>.of(slideProvider.folderPaths)) {
      bool exists;
      try {
        exists = await Directory(path).exists();
      } catch (_) {
        exists = true;
      }
      if (!exists) missing.add(path);
    }
    if (missing.isEmpty || !mounted) return;

    for (final path in missing) {
      slideProvider.removeFolderPath(path);
      settingsProvider.setLastFolderPaths(slideProvider.folderPaths);
    }
    setState(() {
      for (final path in missing) {
        _folderStats.remove(path);
        _scanningFolders.remove(path);
      }
    });
  }

  /// 探测共享源在线状态，加载封面，并启动一轮静默重连
  Future<void> _probeSharedDevices() async {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final refs = List<SharedFolderRef>.of(settings.sharedFolders);
    if (refs.isNotEmpty) {
      await lan.probeSharedDevices(refs);
      if (!mounted) return;
      await lan.loadSharedFolderCovers(refs);
    }
    if (!mounted) return;
    _startSharedReconnectCycle();
  }

  /// 对离线共享文件夹按 2s / 5s / 10s 退避静默重试，最多 3 次。
  ///
  /// 与 LanProvider 的全局 15 秒轮询互为补充：进入本页时先快速重试几次，
  /// 设备刚好恢复在线时无需等待下一个全局周期。
  void _startSharedReconnectCycle() {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _attemptSharedReconnect();
  }

  void _attemptSharedReconnect() {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final offline = [
      for (final ref in settings.sharedFolders)
        if (!lan.isDeviceReachable(ref.deviceId)) ref,
    ];
    if (offline.isEmpty) {
      _reconnectAttempt = 0;
      return;
    }
    if (_reconnectAttempt >= 3) return;

    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];
    final delay = delays[_reconnectAttempt];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () async {
      if (!mounted) return;
      await lan.probeSharedDevices(offline);
      if (!mounted) return;
      // 静默刷新，不弹失败提示，避免自动重试打扰用户
      await lan.refreshSharedFolders(offline);
      if (!mounted) return;
      await lan.loadSharedFolderCovers(offline);
      if (!mounted) return;
      _attemptSharedReconnect();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅路由事件：从子页面（已排除分组 / 文件夹瀑布流 / 播放页）返回时重新统计
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      appRouteObserver.subscribe(this, route);
      _route = route;
    }
    // 当递归扫描设置变化时，重新计算所有文件夹的统计信息
    final settingsProvider = Provider.of<SettingsProvider>(context);
    final previous = _previousRecursiveScan;
    _previousRecursiveScan = settingsProvider.recursiveScan;
    if (previous != null && previous != settingsProvider.recursiveScan) {
      _refreshStats();
    }
  }

  /// 从子页面返回本页时，文件可能已被移走或删除，重新统计并刷新共享状态。
  ///
  /// 延后到当前帧结束再执行，避免在路由回调里直接触发 setState。
  @override
  void didPopNext() {
    Future.microtask(() {
      if (!mounted) return;
      _refreshStats();
      _probeSharedDevices();
    });
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _reconnectTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    super.dispose();
  }

  /// 键盘快捷键：ESC 返回主界面
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，而瀑布流页也注册了
  /// ESC，因此这里必须确认本页位于最上层，否则同一次按键会被两页各处理一次。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // 返回主界面
      Navigator.maybePop(context);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.selectVideos),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
      ),
      body: Consumer3<SlideProvider, SettingsProvider, LanProvider>(
        builder:
            (context, slideProvider, settingsProvider, lanProvider, child) {
              final localPaths = slideProvider.folderPaths;
              final sharedRefs = settingsProvider.sharedFolders;
              final excludedGroups = _buildExcludedGroups(settingsProvider);
              final anySharedOffline = sharedRefs.any(
                (ref) => !lanProvider.isDeviceReachable(ref.deviceId),
              );
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: Platform.isAndroid ? 8 : 16,
                  vertical: 16,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          if (localPaths.isNotEmpty) ...[
                            KeyedSubtree(
                              key: const ValueKey('local-header'),
                              child: _buildSectionHeader(
                                title: loc.localFoldersSection,
                                actionsInline: true,
                                actions: [
                                  _actionButton(
                                    tooltip: loc.playLocalFolders,
                                    icon: const Icon(
                                      Icons.play_circle_outline,
                                      color: Colors.green,
                                    ),
                                    onPressed: _isScanning
                                        ? null
                                        : _playLocalSection,
                                  ),
                                ],
                              ),
                            ),
                            for (final path in localPaths)
                              _buildLocalFolderTile(path),
                          ],
                          if (localPaths.isNotEmpty && sharedRefs.isNotEmpty)
                            const Divider(height: 1, color: Colors.grey),
                          if (sharedRefs.isNotEmpty) ...[
                            KeyedSubtree(
                              key: const ValueKey('shared-header'),
                              child: _buildSectionHeader(
                                title: loc.sharedFoldersSection,
                                actionsInline: true,
                                actions: [
                                  if (anySharedOffline)
                                    _actionButton(
                                      tooltip: loc.lanReconnectAll,
                                      icon: const Icon(Icons.refresh),
                                      onPressed: () =>
                                          _reconnectShared(sharedRefs),
                                    )
                                  else
                                    _actionButton(
                                      tooltip: loc.playSharedFolders,
                                      icon: const Icon(
                                        Icons.play_circle_outline,
                                        color: Colors.green,
                                      ),
                                      onPressed: _isScanning
                                          ? null
                                          : _playSharedSection,
                                    ),
                                ],
                              ),
                            ),
                            for (final ref in sharedRefs)
                              _buildSharedFolderTile(ref, lanProvider),
                          ],
                          if (excludedGroups.isNotEmpty) ...[
                            if (localPaths.isNotEmpty || sharedRefs.isNotEmpty)
                              const Divider(height: 1, color: Colors.grey),
                            _buildExcludedHeader(excludedGroups),
                            for (final group in excludedGroups)
                              _buildExcludedGroupTile(group),
                          ],
                        ],
                      ),
                    ),
                    // 操作按钮
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _addFolder,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0984e3),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 3,
                              shadowColor: const Color(
                                0xFF0984e3,
                              ).withValues(alpha: 0.3),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.add, size: 24),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    AppLocalizations.of(context).addFolder,
                                    style: const TextStyle(fontSize: 16),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _addShareSource,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00cec9),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 3,
                              shadowColor: const Color(
                                0xFF00cec9,
                              ).withValues(alpha: 0.3),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.add_link, size: 24),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    AppLocalizations.of(context).addShareSource,
                                    style: const TextStyle(fontSize: 16),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isScanning ? null : _scanVideos,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00b894),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 4,
                          shadowColor: const Color(
                            0xFF00b894,
                          ).withValues(alpha: 0.4),
                        ),
                        child: _isScanning
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.play_circle, size: 24),
                                  const SizedBox(width: 12),
                                  Text(
                                    AppLocalizations.of(context).startPlay,
                                    style: const TextStyle(fontSize: 18),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
      ),
    );
  }

  /// 相册缩略图组件 - 从 MediaStore 或文件系统加载第一个视频作为缩略图
  Widget _albumThumbnail({
    required String? thumbnailPath,
    required String albumPath,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 48,
        height: 48,
        child: _ThumbnailVideo(
          key: ValueKey('album-thumb-$albumPath-$thumbnailPath'),
          thumbnailPath: thumbnailPath,
          albumPath: albumPath,
        ),
      ),
    );
  }
}

/// 异步加载缩略图的 StatefulWidget
class _ThumbnailVideo extends StatefulWidget {
  final String? thumbnailPath;
  final String albumPath;

  const _ThumbnailVideo({
    super.key,
    required this.thumbnailPath,
    required this.albumPath,
  });

  @override
  State<_ThumbnailVideo> createState() => _ThumbnailVideoState();
}

class _ThumbnailVideoState extends State<_ThumbnailVideo> {
  VideoThumbnail? _thumbnail;
  bool _loading = true;

  /// 每次发起加载时递增，用于识别“过期结果”。
  /// 只要这个值变了，就说明当前请求已不再是该 State 的最新请求。
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ThumbnailVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只要缩略图来源（缩略图路径或所属相册/文件夹路径）发生变化就要重新加载。
    // 否则 ListView 按位置复用 State 时，会残留上一个条目的缩略图，
    // 导致所有文件夹都显示成同一个被排除的视频首帧。
    if (oldWidget.thumbnailPath != widget.thumbnailPath ||
        oldWidget.albumPath != widget.albumPath) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final requestId = ++_requestId;

    setState(() {
      _loading = true;
      // 必须清空旧图：否则下面的“优先取给定缩略图，失败再回退到目录首个视频”
      // 会因为 _thumbnail 非空而被跳过，直接把上一个文件夹的缩略图继续显示出来
      _thumbnail = null;
    });

    // 结果先写局部变量，只有确认请求仍然有效才提交到 State，
    // 避免为文件夹 A 发起的取帧把文件夹 B 的缩略图覆盖掉
    VideoThumbnail? thumbnail;

    try {
      final given = widget.thumbnailPath;
      if (given != null && given.isNotEmpty) {
        thumbnail = await VideoThumbnailService.thumbnailFor(given);
      }
      // 相册返回的缩略图路径可能是 content:// URI，取帧失败时
      // 回退到该目录下的第一个视频
      thumbnail ??= await _firstVideoThumbnail(widget.albumPath);
    } catch (_) {}

    // 如果在加载期间已发起了新的请求（widget 被复用指向其他文件夹），
    // 丢弃本次结果，同时把 _loading 交还给新请求，不能提前置为 false
    if (!mounted || requestId != _requestId) return;

    setState(() {
      _thumbnail = thumbnail;
      _loading = false;
    });
  }

  /// 取目录中第一个视频的首帧作为缩略图回退方案。
  ///
  /// Android 上不能直接用 dart:io 枚举 scoped storage 路径——
  /// 那些路径对应用不可见，既读不到内容还要白白付出一次目录遍历，
  /// 因此改走 MediaStore 拿到真实路径后再交由原生取帧。
  static Future<VideoThumbnail?> _firstVideoThumbnail(String folderPath) async {
    if (Platform.isAndroid) {
      final videos = await MediaStoreService.getFolderVideos(folderPath);
      for (final item in videos) {
        if (!isSupportedVideoPath(item.path)) continue;
        final thumbnail = await VideoThumbnailService.thumbnailFor(item.path);
        if (thumbnail != null) return thumbnail;
      }
      return null;
    }

    final dir = Directory(folderPath);
    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          if (!isSupportedVideoPath(entity.path)) continue;
          final thumbnail = await VideoThumbnailService.thumbnailFor(
            entity.path,
          );
          if (thumbnail != null) return thumbnail;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: const Color(0xFF1a1a2e),
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFe94560),
            ),
          ),
        ),
      );
    }

    final thumbnail = _thumbnail;
    if (thumbnail != null) {
      // 缩略图容器最大 48dp，且帧最长边仅 512px，按真实尺寸解码即可。
      return Image.memory(
        thumbnail.bytes,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: (48 * MediaQuery.of(context).devicePixelRatio * 2)
            .round()
            .clamp(1, thumbnail.width),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF1a1a2e),
      child: const Icon(
        Icons.movie_outlined,
        color: Colors.blueAccent,
        size: 24,
      ),
    );
  }
}

/// 已排除视频按所在文件夹划分出的一个分组
class _ExcludedGroup {
  final String name;
  final List<String> paths;

  const _ExcludedGroup(this.name, this.paths);
}

/// “添加共享源”弹窗的选择结果：device 为空表示需要手动输入地址
class _ShareSourcePick {
  final LanDevice? device;

  const _ShareSourcePick(this.device);
}
