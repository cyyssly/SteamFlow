import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/screens/folder_selection_screen.dart';
import 'package:steam_flow/screens/help_screen.dart';
import 'package:steam_flow/screens/lan_devices_screen.dart';
import 'package:steam_flow/services/open_video_from_path.dart';
import 'package:steam_flow/services/video_scan_service.dart';
import 'package:steam_flow/utils/filename_compare.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  /// 由右键菜单/命令行传入、启动后直接播放的视频路径
  final String? initialVideoPath;

  const HomeScreen({super.key, this.initialVideoPath});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isAutoScanning = false;

  /// 当前扫描的中止标记：播放页在扫描结束前被关闭时置为已中止
  _ScanToken? _scanToken;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    if (widget.initialVideoPath != null) {
      // 从右键菜单打开：跳过自动扫描，直接播放该视频
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialVideo());
    } else {
      // 首帧之后再读本地化文案并开始自动播放
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoPlayOnStartup();
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    _scanToken?.aborted = true;
    super.dispose();
  }

  /// 键盘快捷键：Enter 等同于点击「开始播放」。
  ///
  /// [HardwareKeyboard] 会无条件调用所有已注册的 handler，因此这里必须确认
  /// 本页位于最上层，避免在播放页内按 Enter 又触发一次播放。
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // 扫描进行中忽略重复触发（连按 Enter / 连续点击）
      if (_isAutoScanning) return true;
      _startPlayback();
      return true;
    }
    return false;
  }

  /// 从右键菜单/命令行参数打开视频：扫描同目录、排序，从入口视频开始播放。
  Future<void> _openInitialVideo() async {
    final path = widget.initialVideoPath;
    if (!mounted || path == null) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    await OpenVideoFromPath.openVideo(
      navigator: Navigator.of(context),
      slideProvider: slideProvider,
      settings: settingsProvider,
      videoPath: path,
    );
  }

  /// 进入播放页并等待其关闭；关闭后把本次扫描标记为已中止。
  Future<void> _enterPlayerAndWatchClose(_ScanToken token) async {
    try {
      await Navigator.pushNamed(context, '/player');
    } finally {
      token.aborted = true;
      // 播放页关闭即中止扫描，并立即收起播放页中央的扫描提示；
      // 扫描流程的 finally 会因 token 已中止而跳过清理。
      if (identical(_scanToken, token)) {
        if (!mounted) {
          _isAutoScanning = false;
        } else {
          Provider.of<SlideProvider>(
            context,
            listen: false,
          ).setScanning(false);
          setState(() => _isAutoScanning = false);
        }
      }
    }
  }

  Future<void> _autoPlayOnStartup() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    // 如果没有文件夹路径，直接返回
    if (slideProvider.folderPaths.isEmpty) {
      return;
    }

    // 未开启自动播放时不做任何扫描，停留在主界面
    if (!settingsProvider.autoPlay) {
      return;
    }

    final loc = AppLocalizations.of(context);
    setState(() {
      _isAutoScanning = true;
    });

    // 立即进入播放页：扫描在后台进行，提示显示在播放页中央。
    // 清空上一次的播放列表，避免播放页先用旧视频显示/播放。
    slideProvider.setVideos(const []);
    slideProvider.setScanning(true, statusText: loc.scanning);
    final token = _scanToken = _ScanToken();
    unawaited(_enterPlayerAndWatchClose(token));

    try {
      // 使用 Map 进行去重
      final uniqueVideos = <String, VideoItem>{};
      bool hasStartedPlaying = false;
      DateTime lastUpdateTime = DateTime.now();
      const updateInterval = Duration(milliseconds: 300);
      final bool isRandomMode = settingsProvider.playOrder == PlayOrder.random;

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final videos = await _scanFolder(folderPath, settingsProvider);
        if (token.aborted) return;
        for (final video in videos) {
          if (!uniqueVideos.containsKey(video.path)) {
            uniqueVideos[video.path] = video;
          }

          // 随机模式：边扫描边播放，每隔300ms增量更新列表
          if (isRandomMode) {
            final now = DateTime.now();
            if (now.difference(lastUpdateTime) >= updateInterval) {
              final newVideos = uniqueVideos.values.toList();
              sortByFileName(newVideos, (video) => video.name);
              if (hasStartedPlaying) {
                slideProvider.addNewVideos(
                  newVideos,
                  settingsProvider.playOrder,
                );
              } else {
                slideProvider.setVideos(
                  newVideos,
                  playOrder: settingsProvider.playOrder,
                );
                slideProvider.sortByPlayOrder(settingsProvider.playOrder);
              }
              lastUpdateTime = now;
            }
          }
        }

        // 随机模式：收集到>=10个且未开始播放 → 提前开始（仅随机模式）
        if (isRandomMode && !hasStartedPlaying && uniqueVideos.length >= 10) {
          await _startPlaybackEarly(
            uniqueVideos.values.toList(),
            slideProvider,
            settingsProvider,
            token,
          );
          hasStartedPlaying = true;
        }
      }

      if (token.aborted) return;

      // 所有文件夹扫描完毕
      final allVideos = uniqueVideos.values.toList();
      sortByFileName(allVideos, (video) => video.name);

      if (allVideos.isEmpty) return;

      if (hasStartedPlaying) {
        // 随机模式已提前播放：增量添加剩余新视频
        slideProvider.addNewVideos(allVideos, settingsProvider.playOrder);
      } else {
        // 非随机模式（或视频不足10个）：全量设置并排序后开始播放
        slideProvider.setVideos(
          allVideos,
          playOrder: settingsProvider.playOrder,
        );
        slideProvider.sortByPlayOrder(settingsProvider.playOrder);

        slideProvider.goToStartPosition(settingsProvider.playOrder);
        slideProvider.startPlay();
      }
    } catch (e) {
      debugPrint('自动扫描失败: $e');
    } finally {
      // 扫描被中止时状态已由 _enterPlayerAndWatchClose 重置，这里跳过
      if (!token.aborted) {
        slideProvider.setScanning(false);
        if (mounted) {
          setState(() {
            _isAutoScanning = false;
          });
        }
      }
    }
  }

  Future<void> _startPlaybackEarly(
    List<VideoItem> videos,
    SlideProvider slideProvider,
    SettingsProvider settingsProvider,
    _ScanToken token,
  ) async {
    // 对已收集的视频进行排序
    final sortedVideos = videos.toList();
    sortByFileName(sortedVideos, (video) => video.name);

    slideProvider.setVideos(
      sortedVideos,
      playOrder: settingsProvider.playOrder,
    );
    slideProvider.sortByPlayOrder(settingsProvider.playOrder);

    await Future.delayed(const Duration(milliseconds: 300));

    // 扫描已被中止（用户退出了播放页）时不再开始播放
    if (!mounted || token.aborted) return;
    slideProvider.goToStartPosition(settingsProvider.playOrder);
    slideProvider.startPlay();
  }

  Future<List<VideoItem>> _scanFolder(
    String folderPath,
    SettingsProvider settings,
  ) => VideoScanService.scanFolder(folderPath, settings);

  Future<void> _startPlayback() async {
    // 扫描进行中（含启动自动播放的扫描）忽略重复触发：
    // 否则连点会重复打开播放页、重复扫描
    if (_isAutoScanning) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    if (slideProvider.folderPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).msgSelectFolderFirst),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    final loc = AppLocalizations.of(context);
    _isAutoScanning = true;

    // 点击播放立即进入播放页：扫描在后台进行，播放页中央显示扫描提示。
    // 清空上一次的播放列表，避免播放页先用旧视频显示/播放。
    slideProvider.stopPlay();
    slideProvider.setVideos(const []);
    slideProvider.setScanning(true, statusText: loc.scanning);
    final token = _scanToken = _ScanToken();
    unawaited(_enterPlayerAndWatchClose(token));

    try {
      // 使用 Map 进行去重
      final uniqueVideos = <String, VideoItem>{};

      // 逐个扫描文件夹
      for (final folderPath in slideProvider.folderPaths) {
        final videos = await _scanFolder(folderPath, settingsProvider);
        // 扫描途中已退出播放页：不再写入结果
        if (token.aborted) return;
        for (final video in videos) {
          if (!uniqueVideos.containsKey(video.path)) {
            uniqueVideos[video.path] = video;
          }
        }
      }

      if (!mounted || token.aborted) return;

      // 按文件名排序
      final sortedVideos = uniqueVideos.values.toList();
      sortByFileName(sortedVideos, (video) => video.name);

      if (sortedVideos.isEmpty) {
        _leavePlayerAndWarn(loc.msgReselectFolder);
        return;
      }

      slideProvider.setVideos(
        sortedVideos,
        playOrder: settingsProvider.playOrder,
      );
      slideProvider.sortByPlayOrder(settingsProvider.playOrder);

      slideProvider.goToStartPosition(settingsProvider.playOrder);
      slideProvider.startPlay();
    } catch (e) {
      debugPrint('扫描视频失败: $e');
      if (!mounted) return;
      _leavePlayerAndWarn(AppLocalizations.of(context).msgScanError);
    } finally {
      // 扫描被中止时状态已由 _enterPlayerAndWatchClose 重置，这里跳过
      if (!token.aborted) {
        slideProvider.setScanning(false);
        if (mounted) {
          setState(() {
            _isAutoScanning = false;
          });
        }
      }
    }
  }

  /// 扫描没有得到可播放的视频时，先退回本页再提示，
  /// 避免提示被刚刚打开的播放页遮挡。
  void _leavePlayerAndWarn(String message) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _selectFolder(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const FolderSelectionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).homeTitle),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: ElevatedButton(
                onPressed: () => _startPlayback(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00b894),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 4,
                  shadowColor: const Color(0xFF00b894).withValues(alpha: 0.4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.play_circle, size: 24),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).startPlay,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: isAndroid
                  ? ElevatedButton(
                      onPressed: () => _selectFolder(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0984e3),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
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
                          const Icon(Icons.video_library, size: 24),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              AppLocalizations.of(context).selectVideos,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 18),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ElevatedButton(
                      onPressed: () => _selectFolder(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0984e3),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
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
                          const Icon(Icons.folder_open, size: 24),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              AppLocalizations.of(context).selectVideos,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LanDevicesScreen()),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00b894),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 3,
                  shadowColor: const Color(0xFF00b894).withValues(alpha: 0.3),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lan_outlined, size: 24),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).lanSharePageTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: ElevatedButton(
                onPressed: () => Navigator.pushNamed(context, '/settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6c5ce7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 3,
                  shadowColor: const Color(0xFF6c5ce7).withValues(alpha: 0.3),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.settings, size: 24),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).settings,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: ElevatedButton(
                onPressed: () => Navigator.pushNamed(context, '/help'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFe17055),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 3,
                  shadowColor: const Color(0xFFe17055).withValues(alpha: 0.3),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.help_outline, size: 24),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).help,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              appVersionLabel,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一次「扫描并播放」流程的中止标记。
class _ScanToken {
  bool aborted = false;
}
