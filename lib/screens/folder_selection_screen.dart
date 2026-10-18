import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/screens/excluded_videos_screen.dart';
import 'package:steam_flow/screens/folder_videos_screen.dart';
import 'package:steam_flow/services/directory_picker_service.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/services/video_thumbnail_service.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

class FolderSelectionScreen extends StatefulWidget {
  const FolderSelectionScreen({super.key});

  @override
  State<FolderSelectionScreen> createState() => _FolderSelectionScreenState();
}

class _FolderSelectionScreenState extends State<FolderSelectionScreen> {
  bool _isScanning = false;

  // 缓存每个文件夹的统计信息
  final Map<String, Map<String, int>> _folderStats = {};
  // 跟踪正在计数的文件夹
  final Set<String> _scanningFolders = {};

  /// 正在为该文件夹准备播放（扫描中），用于禁用其播放按钮并显示进度
  final Set<String> _playingFolders = {};

  /// 是否正在添加文件夹（含原生对话框弹出期间），用于防止重复触发
  bool _isAddingFolder = false;

  /// “已排除的文件”虚拟条目的 Key（列表整体位移时需要它才能重新定位）
  static const Key _excludedEntryKey = ValueKey('excluded-entry');

  /// 列表项的 Key -> 当前索引。
  ///
  /// 供 ListView 在“添加/删除文件夹”后把已有的 Element（及其缩略图 State）
  /// 重新绑定到正确的位置，避免按位置复用导致缩略图错乱。
  int? _resolveItemIndex(Key key, List<String> folderPaths, bool hasExcluded) {
    if (key == _excludedEntryKey) {
      return hasExcluded ? 0 : null;
    }
    if (key is ValueKey<String>) {
      final value = key.value;
      if (value.startsWith('folder-')) {
        final path = value.substring('folder-'.length);
        final index = folderPaths.indexOf(path);
        if (index < 0) return null;
        return hasExcluded ? index + 1 : index;
      }
    }
    return null;
  }

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
      const supportedExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

      int videoCount = 0;
      int subfolderCount = 0;

      if (Platform.isAndroid) {
        // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
        final videos = await MediaStoreService.getFolderVideos(folderPath);
        for (final item in videos) {
          final dotIndex = item.path.lastIndexOf('.');
          if (dotIndex != -1) {
            final ext = item.path.toLowerCase().substring(dotIndex + 1);
            if (supportedExtensions.contains(ext)) {
              videoCount++;
            }
          }
        }
      } else if (settingsProvider.recursiveScan) {
        final dir = Directory(folderPath);
        await for (var entity in dir.list(recursive: true)) {
          if (entity is File) {
            final dotIndex = entity.path.lastIndexOf('.');
            if (dotIndex != -1) {
              final ext = entity.path.toLowerCase().substring(dotIndex + 1);
              if (supportedExtensions.contains(ext)) {
                videoCount++;
              }
            }
          } else if (entity is Directory) {
            subfolderCount++;
          }
        }
      } else {
        final dir = Directory(folderPath);
        final entities = await dir.list().toList();
        for (var entity in entities) {
          if (entity is File) {
            final dotIndex = entity.path.lastIndexOf('.');
            if (dotIndex != -1) {
              final ext = entity.path.toLowerCase().substring(dotIndex + 1);
              if (supportedExtensions.contains(ext)) {
                videoCount++;
              }
            }
          }
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

  /// 全部排除：把已选文件夹全部移出播放列表
  void _excludeAll() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    slideProvider.clearFolderPaths();
    settingsProvider.setLastFolderPaths(slideProvider.folderPaths);

    // 清除所有缓存的统计信息
    setState(() {
      _folderStats.clear();
      _scanningFolders.clear();
    });
  }

  /// 构建"已排除的文件"虚拟文件夹条目
  Widget _buildExcludedFolderTile() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final excludedCount = settings.excludedPaths.length;
    final loc = AppLocalizations.of(context);
    // 找第一个仍然存在的已排除视频作为缩略图
    String? firstExcludedPath;
    for (final path in settings.excludedPaths) {
      if (File(path).existsSync()) {
        firstExcludedPath = path;
        break;
      }
    }
    return ListTile(
      key: const ValueKey('excluded-vfolder'),
      // 右侧边距缩小，让 > 图标更靠右，与左侧缩略图边距更平衡
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 40,
          height: 40,
          child: firstExcludedPath != null
              ? _ThumbnailVideo(
                  key: ValueKey('thumb-excluded-$firstExcludedPath'),
                  thumbnailPath: firstExcludedPath,
                  albumPath: firstExcludedPath,
                )
              : Container(
                  color: const Color(0xFF1a1a2e),
                  child: const Icon(
                    Icons.inbox,
                    color: Colors.orange,
                    size: 24,
                  ),
                ),
        ),
      ),
      title: Text(
        loc.excludeFolderVirtual,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        excludedCount > 0
            ? loc.includesVideos(excludedCount)
            : loc.noExcludedVideos,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      // 用与 IconButton 相同尺寸的容器包裹，保证与下方删除按钮竖向对齐
      trailing: const SizedBox(
        width: 48,
        height: 48,
        child: Icon(Icons.chevron_right, color: Colors.grey),
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const ExcludedVideosScreen()),
        );
      },
    );
  }

  Future<void> _scanVideos() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (slideProvider.folderPaths.isEmpty) {
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
      // 使用 Map 进行去重
      final uniqueVideos = <String, VideoItem>{};
      bool hasStartedPlaying = false;
      int lastUpdateCount = 0;

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final videos = await _scanFolder(folderPath, settingsProvider);
        for (final video in videos) {
          if (!uniqueVideos.containsKey(video.path)) {
            uniqueVideos[video.path] = video;
          }

          // 每收集到10个新视频就更新一次列表（播放中）
          if (hasStartedPlaying &&
              uniqueVideos.length - lastUpdateCount >= 10) {
            final newVideos = uniqueVideos.values.toList()
              ..sort((a, b) => a.name.compareTo(b.name));
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

      // 按文件名排序
      final sortedVideos = uniqueVideos.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

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
      ..sort((a, b) => a.name.compareTo(b.name));

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
  ) async {
    const supportedExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

    // Android 端通过 MediaStore 查询（绕过 Scoped Storage 限制）
    if (Platform.isAndroid) {
      // 直接透传 VideoItem，保留 MediaStore 已索引好的宽高比
      final videos = await MediaStoreService.getFolderVideos(folderPath);
      return videos.where((item) {
        final dotIndex = item.path.lastIndexOf('.');
        if (dotIndex == -1) return false;
        final ext = item.path.toLowerCase().substring(dotIndex + 1);
        return supportedExtensions.contains(ext);
      }).toList();
    }

    // 桌面端使用文件系统 API
    List<File> files = [];

    if (settings.recursiveScan) {
      final dir = Directory(folderPath);
      await for (var entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } else {
      final dir = Directory(folderPath);
      final entities = await dir.list().toList();
      files = entities.whereType<File>().toList();
    }

    return files
        .where((file) {
          final dotIndex = file.path.lastIndexOf('.');
          if (dotIndex == -1) return false;
          final ext = file.path.toLowerCase().substring(dotIndex + 1);
          return supportedExtensions.contains(ext);
        })
        .map(
          (file) => VideoItem(
            name: file.path.split(Platform.pathSeparator).last,
            path: file.path,
          ),
        )
        .toList();
  }

  bool _previousRecursiveScan = false;

  @override
  void initState() {
    super.initState();
    // 页面初始化时，对已有的文件夹触发统计计算
    Future.microtask(() {
      if (!mounted) return;
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      _previousRecursiveScan = settingsProvider.recursiveScan;
      for (final path in slideProvider.folderPaths) {
        _countFolderVideos(path);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 当递归扫描设置变化时，重新计算所有文件夹的统计信息
    final settingsProvider = Provider.of<SettingsProvider>(context);
    if (_previousRecursiveScan != settingsProvider.recursiveScan) {
      _previousRecursiveScan = settingsProvider.recursiveScan;
      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      // 清除缓存并重新计算
      setState(() {
        _folderStats.clear();
      });
      for (final path in slideProvider.folderPaths) {
        _countFolderVideos(path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).selectFolderTitle),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
      ),
      body: Consumer2<SlideProvider, SettingsProvider>(
        builder: (context, slideProvider, settingsProvider, child) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 已选文件夹列表
              Expanded(
                child: ListView.builder(
                  itemCount:
                      slideProvider.folderPaths.length +
                      (settingsProvider.excludedPaths.isNotEmpty ? 1 : 0),
                  // 列表会因“添加/删除文件夹”或“排除列表由空变非空”而整体位移。
                  // 若不提供该回调，SliverChildBuilderDelegate.findIndexByKey 会返回
                  // null，Flutter 只能按“位置”复用 Element，于是某个文件夹的条目
                  // （连同其缩略图组件）会被复用到另一个文件夹的路径上，
                  // 出现缩略图张冠李戴的问题。
                  findChildIndexCallback: (Key key) => _resolveItemIndex(
                    key,
                    slideProvider.folderPaths,
                    settingsProvider.excludedPaths.isNotEmpty,
                  ),
                  itemBuilder: (context, index) {
                    final hasExcluded =
                        settingsProvider.excludedPaths.isNotEmpty;
                    // 第一个条目（如果有排除文件）是虚拟的"已排除的文件"文件夹
                    if (hasExcluded && index == 0) {
                      // 外层必须带 Key，findChildIndexCallback 才能把这个条目
                      // 重新映射回位置 0
                      return Column(
                        key: _excludedEntryKey,
                        children: [
                          _buildExcludedFolderTile(),
                          const Divider(height: 1, color: Colors.grey),
                        ],
                      );
                    }
                    final folderIndex = hasExcluded ? index - 1 : index;
                    final path = slideProvider.folderPaths[folderIndex];
                    return ListTile(
                      // 使用稳定的 Key 绑定到文件夹路径，避免 ListView 按位置复用 State，
                      // 导致缩略图组件残留上一个位置的视频
                      key: ValueKey('folder-$path'),
                      // 右侧边距缩小，让删除按钮更靠右，与左侧缩略图边距更平衡
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: _ThumbnailVideo(
                            // 把 State 与所属文件夹绑定：即使 Element 被复用到其他
                            // 位置，Key 不一致也会让 Flutter 重建全新的 State，
                            // 不会残留上一个文件夹已加载的缩略图
                            key: ValueKey('thumb-$path'),
                            thumbnailPath: null,
                            albumPath: path,
                          ),
                        ),
                      ),
                      title: Text(
                        // 安卓端手机宽度有限，只显示最后一级文件夹名；
                        // Windows 端保留完整路径
                        Platform.isAndroid ? _getLastPathSegment(path) : path,
                        style: const TextStyle(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _buildFolderStats(path),
                      // 播放：直接以该文件夹为范围进入播放；
                      // 排除：把该文件夹移出播放列表（原「删除」按钮的动作）
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: AppLocalizations.of(context).playFolder,
                            icon: _playingFolders.contains(path)
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.play_circle_outline,
                                    color: Colors.green,
                                  ),
                            onPressed: _playingFolders.contains(path)
                                ? null
                                : () => _playFolder(path),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: AppLocalizations.of(
                              context,
                            ).excludeFromPlay,
                            icon: const Icon(Icons.block, color: Colors.orange),
                            onPressed: () => _removeFolder(path),
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                FolderVideosScreen(folderPath: path),
                          ),
                        );
                      },
                    );
                  },
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
                          const SizedBox(width: 12),
                          Text(
                            AppLocalizations.of(context).addFolder,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: slideProvider.folderPaths.isEmpty
                          ? null
                          : _excludeAll,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFd63031),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 3,
                        shadowColor: const Color(
                          0xFFd63031,
                        ).withValues(alpha: 0.3),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.block, size: 24),
                          const SizedBox(width: 12),
                          Text(
                            AppLocalizations.of(context).excludeAll,
                            style: const TextStyle(fontSize: 18),
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
                    shadowColor: const Color(0xFF00b894).withValues(alpha: 0.4),
                  ),
                  child: _isScanning
                      ? const CircularProgressIndicator(color: Colors.white)
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
        ),
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

  static const _supportedExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

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
        if (!_supportedExtensions.contains(
          item.path.split('.').last.toLowerCase(),
        )) {
          continue;
        }
        final thumbnail = await VideoThumbnailService.thumbnailFor(item.path);
        if (thumbnail != null) return thumbnail;
      }
      return null;
    }

    final dir = Directory(folderPath);
    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (_supportedExtensions.contains(ext)) {
            final thumbnail = await VideoThumbnailService.thumbnailFor(
              entity.path,
            );
            if (thumbnail != null) return thumbnail;
          }
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
