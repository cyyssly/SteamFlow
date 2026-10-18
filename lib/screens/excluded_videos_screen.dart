import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/directory_picker_service.dart';
import 'package:steam_flow/services/fullscreen_service.dart';
import 'package:steam_flow/services/video_scan_service.dart';
import 'package:steam_flow/services/media_store_service.dart';
import 'package:steam_flow/widgets/masonry_video_grid.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

class ExcludedVideosScreen extends StatefulWidget {
  const ExcludedVideosScreen({super.key});

  @override
  State<ExcludedVideosScreen> createState() => _ExcludedVideosScreenState();
}

class _ExcludedVideosScreenState extends State<ExcludedVideosScreen> {
  List<VideoItem> _excludedItems = [];
  bool _isLoading = true;
  int? _selectedIndex;

  /// 每批处理的视频数量，避免一次性读取过多元数据/解码过多视频
  static const _batchSize = 30;

  @override
  void initState() {
    super.initState();
    _loadExcludedVideos();
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

  void _loadExcludedVideos() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final items = <VideoItem>[];
    for (final path in settings.excludedPaths) {
      final file = File(path);
      if (file.existsSync()) {
        items.add(
          VideoItem(name: path.split(Platform.pathSeparator).last, path: path),
        );
      }
    }
    setState(() {
      _excludedItems = items;
      _isLoading = false;
    });
    // 分批读取宽高比并预解码像素，滚动时无需等待
    unawaited(_loadMetadataAndPrecache(items));
  }

  /// 分批读取宽高比并预解码像素。
  /// 逐个调用会为每个视频创建一个 isolate，这里改为按批读取；
  /// 同时真正把像素解码进 ImageCache，
  /// 否则滚动到新卡片时仍需现场解码，表现为卡顿。
  Future<void> _loadMetadataAndPrecache(List<VideoItem> items) async {
    // 建立 路径→索引 映射，避免每批都做一次 indexWhere 全表扫描
    final indexByPath = <String, int>{};
    for (var i = 0; i < _excludedItems.length; i++) {
      indexByPath[_excludedItems[i].path] = i;
    }

    for (var start = 0; start < items.length; start += _batchSize) {
      if (!mounted) return;
      final end = (start + _batchSize).clamp(0, items.length);
      final batch = items.sublist(start, end);

      // 已带宽高比的项无需再解析
      final pendingIndexes = <int>[];
      final pendingPaths = <String>[];
      for (var i = 0; i < batch.length; i++) {
        if (batch[i].aspectRatio == null) {
          pendingIndexes.add(i);
          pendingPaths.add(batch[i].path);
        }
      }

      if (pendingPaths.isNotEmpty) {
        final ratios = await VideoScanService.readAspectRatios(pendingPaths);
        if (!mounted) return;
        setState(() {
          for (var k = 0; k < pendingPaths.length; k++) {
            final ratio = ratios[k];
            if (ratio == null) continue;
            final i = pendingIndexes[k];
            final item = batch[i];
            final index = indexByPath[item.path];
            if (index == null) continue;
            final updated = VideoItem(
              name: item.name,
              path: item.path,
              aspectRatio: ratio,
            );
            _excludedItems[index] = updated;
            batch[i] = updated;
          }
        });
      }
      // 宽高比已就绪，再预解码像素
      await _precacheBatch(batch);
    }
  }

  /// 预生成一批视频的缩略图，填充缩略图缓存
  Future<void> _precacheBatch(List<VideoItem> batch) async {
    if (!mounted) return;
    await MasonryVideoGrid.precacheAll(batch.map((e) => e.path).toList());
  }

  // ── 单图操作 ──
  void _restoreVideo(String path) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(path);
    setState(() => _excludedItems.removeWhere((item) => item.path == path));
    _showSnack(AppLocalizations.of(context).videoRestored);
  }

  Future<void> _deleteVideo(VideoItem item) async {
    final ok = await MediaStoreService.deleteToTrash([item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
    _showSnack(AppLocalizations.of(context).deletedToTrash);
  }

  Future<void> _moveVideo(VideoItem item) async {
    // Android 用 SAF 选择可写目录（tree uri），其他平台用 FilePicker 选择路径
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final ok = await MediaStoreService.moveFiles(result, [item.path]);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.removeExcludedPath(item.path);
    setState(() => _excludedItems.removeWhere((i) => i.path == item.path));
  }

  Future<void> _copyVideo(VideoItem item) async {
    // Android 用 SAF 选择可写目录（tree uri），其他平台用 FilePicker 选择路径
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final ok = await MediaStoreService.copyFiles(result, [item.path]);
    if (!mounted) return;
    if (ok) {
      _showSnack(AppLocalizations.of(context).copySuccess);
    } else {
      _showSnack(AppLocalizations.of(context).copyFailed);
    }
  }

  /// 选择移动/复制目标目录。
  /// Android 用原生 SAF 返回 content:// tree uri；其他平台用 FilePicker 返回路径。
  /// @return 目标标识（tree uri 或路径），取消返回 null
  Future<String?> _pickDestination() async {
    if (Platform.isAndroid) {
      return MediaStoreService.pickDestinationDir();
    }
    return DirectoryPickerService.pickDirectory();
  }

  // ── 批量操作 ──
  Future<void> _restoreAll() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).allVideosRestored);
  }

  Future<void> _deleteAll() async {
    final paths = _excludedItems.map((e) => e.path).toList();
    final ok = await MediaStoreService.deleteToTrash(paths);
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).deleteFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).deletedAllToTrash);
  }

  Future<void> _moveAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<VideoItem>.from(_excludedItems);
    final ok = await MediaStoreService.moveFiles(
      result,
      items.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    if (!ok) {
      _showSnack(AppLocalizations.of(context).moveFailed);
      return;
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    settings.clearExcludedPaths();
    setState(() => _excludedItems.clear());
    _showSnack(AppLocalizations.of(context).movedAllTo);
  }

  Future<void> _copyAll() async {
    final result = await _pickDestination();
    if (result == null) return;
    if (!mounted) return;
    final items = List<VideoItem>.from(_excludedItems);
    final ok = await MediaStoreService.copyFiles(
      result,
      items.map((e) => e.path).toList(),
    );
    if (!mounted) return;
    if (ok) {
      _showSnack(AppLocalizations.of(context).copiedAllTo);
    } else {
      _showSnack(AppLocalizations.of(context).copyFailed);
    }
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
    // 返回上一页时先退出全屏，避免带着无边框全屏窗口回到上一页
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) FullscreenService.instance.exit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.excludedFolder),
          centerTitle: true,
          backgroundColor: const Color(0xFF16213e),
          actions: [
            if (_excludedItems.isNotEmpty) ...[
              IconButton(
                icon: const Icon(Icons.restore, color: Colors.orange),
                tooltip: loc.restoreAll,
                onPressed: _restoreAll,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                tooltip: loc.deleteAll,
                onPressed: _deleteAll,
              ),
              IconButton(
                icon: const Icon(
                  Icons.drive_file_move_outline,
                  color: Colors.lightBlue,
                ),
                tooltip: loc.moveAllTo,
                onPressed: _moveAll,
              ),
              IconButton(
                icon: const Icon(Icons.content_copy, color: Colors.greenAccent),
                tooltip: loc.copyAllTo,
                onPressed: _copyAll,
              ),
            ],
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _excludedItems.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.inbox, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(
                      loc.noExcludedVideos,
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ],
                ),
              )
            : MasonryVideoGrid(
                items: _excludedItems,
                selectedIndex: _selectedIndex,
                onTap: (index) {
                  setState(() {
                    _selectedIndex = _selectedIndex == index ? null : index;
                  });
                },
                onPrimaryAction: (index) {
                  _restoreVideo(_excludedItems[index].path);
                  if (mounted) setState(() => _selectedIndex = null);
                },
                onDelete: (index) {
                  _deleteVideo(_excludedItems[index]);
                  if (mounted) setState(() => _selectedIndex = null);
                },
                onMove: (index) {
                  _moveVideo(_excludedItems[index]);
                  if (mounted) setState(() => _selectedIndex = null);
                },
                onCopy: (index) {
                  _copyVideo(_excludedItems[index]);
                },
                primaryIcon: Icons.restore,
                primaryColor: Colors.orange,
                primaryTooltip: loc.restore,
              ),
      ),
    );
  }
}
