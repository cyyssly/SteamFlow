import 'dart:io';

import 'package:flutter/material.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/services/video_scan_service.dart';

/// 文件直开：根据视频文件路径构建播放列表并跳转播放页。
///
/// 核心思路：
/// 1. 取视频的直接父目录
/// 2. 判断父目录是否在 [SettingsProvider.lastFolderPaths]（管理列表）中
///    - 在：按该文件夹记录的排序方式（[SettingsProvider.localSortFor]）加载；
///      未记录时跟随设置页默认播放顺序
///    - 不在：只扫描当前目录（不递归），按设置页默认播放顺序加载
/// 3. 找到用户点的那个视频在排序列表中的索引，从它开始播放
class OpenVideoFromPath {
  /// 把 [SettingsProvider.localSortFor] 返回的排序名字符串（来自
  /// [folder_videos_screen.dart] 内部枚举 [_SortAction] 的 `.name`）
  /// 反查为 [PlayOrder]；未知或 null 时回退到 [fallback]（通常是
  /// [SettingsProvider.playOrder]）。
  static PlayOrder playOrderForSortName(
    String? sortName, {
    required PlayOrder fallback,
  }) {
    if (sortName == null) return fallback;
    switch (sortName) {
      case 'nameAsc':
        return PlayOrder.sequential;
      case 'nameDesc':
        return PlayOrder.reverseSequential;
      case 'timeNewest':
        return PlayOrder.newestFirst;
      case 'timeOldest':
        return PlayOrder.oldestFirst;
      case 'sizeLargest':
        return PlayOrder.sizeLargest;
      case 'sizeSmallest':
        return PlayOrder.sizeSmallest;
      case 'random':
        return PlayOrder.random;
      case 'newPreferred':
        return PlayOrder.newPreferred;
      default:
        return fallback;
    }
  }

  /// Windows 下做大小写不敏感的路径精确匹配。
  static bool _pathEquals(String a, String b) {
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  /// 扫描视频所在的父目录，并返回"未排序的视频列表"和"推荐的排序方式"。
  ///
  /// - 父目录在管理列表：跟随该文件夹记录的排序（未记录则回退全局默认）；
  ///   扫描递归策略也跟随全局设置。
  /// - 父目录不在管理列表：强制只扫当前目录（不递归），排序跟随全局默认。
  ///
  /// 返回 null 表示父目录不存在或扫描结果为空。
  static Future<(List<VideoItem>, PlayOrder)?> scanWithOrder(
    String videoPath,
    SettingsProvider settings,
  ) async {
    final file = File(videoPath);
    if (!await file.exists()) return null;
    final parentDir = file.parent.path;

    // 父目录是否在管理列表中（精确匹配）
    bool managed = false;
    for (final folder in settings.lastFolderPaths) {
      if (_pathEquals(folder, parentDir)) {
        managed = true;
        break;
      }
    }

    // 未管理目录：强制只扫当前目录；管理目录跟随全局递归设置
    final items = await VideoScanService.scanFolder(
      parentDir,
      settings,
      recursiveOverride: managed ? null : false,
    );
    if (items.isEmpty) return null;

    // 确定 PlayOrder
    final order = managed
        ? playOrderForSortName(
            settings.localSortFor(parentDir),
            fallback: settings.playOrder,
          )
        : settings.playOrder;

    return (items, order);
  }

  /// 打开视频：构建播放列表，定位到入口视频，导航到播放页。
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
    final result = await scanWithOrder(videoPath, settings);
    if (result == null) return;
    final (videos, order) = result;

    if (popFirst && navigator.mounted) {
      navigator.popUntil((route) => route.isFirst);
    }

    slideProvider.setVideos(videos);
    slideProvider.sortByPlayOrder(order);

    final idx = slideProvider.videos.indexWhere(
      (v) => _pathEquals(v.path, videoPath),
    );
    slideProvider.goToVideo(idx >= 0 ? idx : 0);
    slideProvider.startPlay();

    if (navigator.mounted) {
      navigator.pushNamed('/player');
    }
  }
}
