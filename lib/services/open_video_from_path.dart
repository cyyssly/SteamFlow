import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/services/explorer_sort_service.dart';
import 'package:steam_flow/services/video_scan_service.dart';

/// 文件直开：根据视频文件路径构建播放列表并跳转播放页。
///
/// 核心思路：
/// 1. 取视频的直接父目录
/// 2. 扫描该目录（**不包含子文件夹**），排除记录仍然生效
/// 3. 播放列表按资源管理器当前视图的排序方式排列（名称/修改日期/大小及方向），
///    保证播放顺序与用户肉眼在资源管理器里看到的顺序一致；
///    读不到（目录未在资源管理器打开、按类型排序等）时回退到名称自然序
/// 4. 找到用户点的那个视频在排序列表中的索引，从它开始播放
class OpenVideoFromPath {
  /// Windows 下做大小写不敏感的路径精确匹配。
  static bool _pathEquals(String a, String b) {
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  /// 扫描视频所在的父目录，并返回"未排序的视频列表"和"推荐的排序方式"。
  ///
  /// 只扫描当前文件夹，不递归子文件夹；排序方式取资源管理器该目录窗口
  /// 当前的视图排序（名称/修改日期/大小及方向）。
  ///
  /// 返回 null 表示父目录不存在或扫描结果为空。
  static Future<(List<VideoItem>, PlayOrder)?> scanWithOrder(
    String videoPath,
    SettingsProvider settings,
  ) async {
    final file = File(videoPath);
    if (!await file.exists()) return null;
    final parentDir = file.parent.path;

    final items = await VideoScanService.scanFolder(
      parentDir,
      settings,
      recursiveOverride: false,
    );
    if (items.isEmpty) return null;

    // 与用户在资源管理器里看到的顺序保持一致：读取该目录窗口当前的
    // 排序列与方向；读不到时回退到按名称自然序
    final order =
        await ExplorerSortService.readPlayOrder(parentDir) ??
        PlayOrder.sequential;

    return (items, order);
  }

  /// 打开视频：先立即进入播放页显示被打开的视频，再在后台补全播放列表。
  ///
  /// - [popFirst] 跳转前是否先 pop 到根路由。单实例转发场景需要清掉
  ///   当前可能残留的播放页；新实例首次启动不需要。
  static Future<void> openVideo({
    required NavigatorState navigator,
    required SlideProvider slideProvider,
    required SettingsProvider settings,
    required String videoPath,
    bool popFirst = false,
  }) async {
    // 双击打开的视频若属于某个媒体库，先切到该库，让界面与播放内容一致；
    // 不在任何库内则保持当前库不变。
    if (settings.switchToLibraryForPath(videoPath)) {
      slideProvider.setFolderPaths(settings.lastFolderPaths);
    }

    // 文件不存在则不做任何跳转，避免播放页打开一个无效视频
    if (!await File(videoPath).exists()) return;

    // 先用被打开的视频直接进入播放页。同目录扫描在大文件夹里要花数秒，
    // 若等扫描结束再跳转，用户会先盯着上一个界面/上一个视频等待，
    // 表现为「双击后迟迟不切到新视频」。
    slideProvider.setVideos([
      VideoItem(
        name: videoPath.split(Platform.pathSeparator).last,
        path: videoPath,
      ),
    ]);
    slideProvider.startPlay();

    if (popFirst && navigator.mounted) {
      navigator.popUntil((route) => route.isFirst);
    }
    if (!navigator.mounted) return;
    unawaited(navigator.pushNamed('/player'));

    // 后台补全同目录的播放列表，完成后原地替换（显示中的视频不变）
    final result = await scanWithOrder(videoPath, settings);
    if (result == null || !navigator.mounted) return;
    final (videos, order) = result;
    // 扫描期间用户可能已经关掉播放页、或换了别的视频，此时不要覆盖当前列表
    if (slideProvider.videos.length != 1 ||
        !_pathEquals(slideProvider.videos.first.path, videoPath)) {
      return;
    }

    slideProvider.replaceVideosKeeping(videoPath, videos, order);
  }
}
