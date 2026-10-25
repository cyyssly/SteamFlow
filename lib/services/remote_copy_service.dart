import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/services/directory_picker_service.dart';
import 'package:steam_flow/services/lan_client_service.dart';
import 'package:steam_flow/services/media_store_service.dart';

/// 远端视频复制结果
enum RemoteCopyStatus { success, cancelled, failed, busy }

/// 复用上次复制目录弹窗中的选择
enum _CopyDestinationChoice { cancel, change, useLast }

/// 远端视频复制到本机的公共流程，瀑布流页面与播放页共用。
class RemoteCopyService {
  RemoteCopyService._();

  /// 同一时间只允许一个复制任务，避免播放页与瀑布流各弹一个进度框
  static bool _copying = false;

  static bool get isCopying => _copying;

  /// 解析目标目录：优先询问是否沿用上次目录，未记录时直接弹出选择器。
  static Future<String?> resolveDestination(BuildContext context) async {
    final loc = AppLocalizations.of(context);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final last = settings.lastCopyDestination;
    if (last != null && last.isNotEmpty) {
      final choice = await showDialog<_CopyDestinationChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF16213e),
          title: Text(loc.lanCopyToLocal),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.lastCopyDestination,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                displayDestination(last),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.cancel),
              child: Text(loc.lanCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.change),
              child: Text(loc.changeDestination),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CopyDestinationChoice.useLast),
              child: Text(loc.startCopy),
            ),
          ],
        ),
      );
      if (!context.mounted) return null;
      if (choice == _CopyDestinationChoice.useLast) return last;
      if (choice != _CopyDestinationChoice.change) return null;
    }

    final picked = await pickDestination();
    if (picked != null && picked.isNotEmpty) {
      settings.setLastCopyDestination(picked);
    }
    return picked;
  }

  /// 弹出系统目录选择器（Android 为 SAF，桌面为文件夹选择器）
  static Future<String?> pickDestination() {
    return Platform.isAndroid
        ? MediaStoreService.pickDestinationDir()
        : DirectoryPickerService.pickDirectory();
  }

  /// 把目标目录转成便于阅读的文本（SAF tree uri 解码为可读路径）
  static String displayDestination(String destination) {
    if (!destination.startsWith('content://')) return destination;
    var value = destination;
    final treeIndex = value.indexOf('/tree/');
    if (treeIndex >= 0) value = value.substring(treeIndex + 6);
    final queryIndex = value.indexOf('?');
    if (queryIndex >= 0) value = value.substring(0, queryIndex);
    try {
      value = Uri.decodeComponent(value);
    } catch (_) {
      // 解码失败时保留原值
    }
    return value.replaceAll(':', ' / ');
  }

  /// 下载远端视频并写入目标目录。
  ///
  /// 下载过程显示进度对话框，支持取消与断点续传：
  /// 分片文件保存在应用支持目录，取消或失败后下次会从断点继续，
  /// 成功转存后才删除分片及其元数据。
  static Future<RemoteCopyStatus> copyToLocal(
    BuildContext context,
    VideoItem item,
    String destination,
  ) async {
    if (_copying) return RemoteCopyStatus.busy;
    _copying = true;
    try {
      return await _copyToLocalInternal(context, item, destination);
    } finally {
      _copying = false;
    }
  }

  static Future<RemoteCopyStatus> _copyToLocalInternal(
    BuildContext context,
    VideoItem item,
    String destination,
  ) async {
    final loc = AppLocalizations.of(context);
    final progress = ValueNotifier<(int, int)>((0, 0));
    final dialogReady = Completer<void>();
    BuildContext? dialogContext;
    var cancelled = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          if (!dialogReady.isCompleted) dialogReady.complete();
          return AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: Text(loc.lanCopying),
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (context, value, _) {
                final received = value.$1;
                final total = value.$2;
                final ratio = total > 0
                    ? (received / total).clamp(0.0, 1.0).toDouble()
                    : null;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: ratio,
                      color: const Color(0xFFe94560),
                      backgroundColor: Colors.white12,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      ratio == null
                          ? _formatBytes(received)
                          : '${_formatBytes(received)} / '
                                '${_formatBytes(total)}  '
                                '(${(ratio * 100).toStringAsFixed(0)}%)',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => cancelled = true,
                child: Text(loc.lanCancel),
              ),
            ],
          );
        },
      ),
    );
    // 等对话框真正挂载后再开始下载，确保结束时能主动关闭它
    await dialogReady.future;

    Directory? tempDir;
    var status = RemoteCopyStatus.failed;
    try {
      final dir = await _downloadDir();
      final partFile = File('${dir.path}/${_partFileName(item)}');
      final download = await LanClientService.instance.downloadVideo(
        item.playbackUrl,
        partFile,
        onProgress: (received, total) => progress.value = (received, total),
        isCancelled: () => cancelled,
      );
      switch (download) {
        case DownloadStatus.cancelled:
          status = RemoteCopyStatus.cancelled;
          break;
        case DownloadStatus.failed:
          status = RemoteCopyStatus.failed;
          break;
        case DownloadStatus.success:
          final saved = await _saveToDestination(item, partFile, destination);
          tempDir = saved.$2;
          status = saved.$1
              ? RemoteCopyStatus.success
              : RemoteCopyStatus.failed;
          break;
      }
      if (status == RemoteCopyStatus.success) {
        try {
          await partFile.delete();
        } catch (_) {
          // 分片清理失败不影响结果
        }
        try {
          await File('${partFile.path}.meta').delete();
        } catch (_) {
          // 元数据清理失败不影响结果
        }
      }
    } catch (_) {
      status = RemoteCopyStatus.failed;
    } finally {
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }
      progress.dispose();
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {
        // 临时文件清理失败不影响结果
      }
    }
    return status;
  }

  /// 把已下载完成的分片转存到用户选择的目标目录。
  ///
  /// 返回「是否成功」以及需要清理的临时目录（仅 Android SAF 会用到）。
  static Future<(bool, Directory?)> _saveToDestination(
    VideoItem item,
    File partFile,
    String destination,
  ) async {
    if (Platform.isAndroid) {
      // SAF 只能复制完整文件，先转存为原始文件名再交给系统
      final tempDir = await Directory.systemTemp.createTemp('steam_flow_copy_');
      final staged = File('${tempDir.path}/${_fileNameFor(item)}');
      await partFile.copy(staged.path);
      final ok = await MediaStoreService.copyFiles(destination, [staged.path]);
      return (ok, tempDir);
    }
    final target = await uniqueDesktopTarget(destination, _fileNameFor(item));
    await partFile.copy(target);
    return (true, null);
  }

  /// 桌面端生成不覆盖已有文件的目标路径（重名时追加 _1、_2…）
  static Future<String> uniqueDesktopTarget(String dir, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = name;
    var index = 1;
    while (await File('$dir${Platform.pathSeparator}$candidate').exists()) {
      candidate = '${base}_$index$ext';
      index++;
    }
    return '$dir${Platform.pathSeparator}$candidate';
  }

  /// 取只含文件名的安全名称，避免远端返回的路径片段被拼进目标路径
  static String _fileNameFor(VideoItem item) {
    final name = item.name.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty || name == '.' || name == '..') {
      return 'steam_flow_${DateTime.now().microsecondsSinceEpoch}.video';
    }
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// 分片文件的存放目录：应用支持目录，重启后仍可续传
  static Future<Directory> _downloadDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}steam_flow_downloads',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 分片文件名：稳定哈希 + 原始文件名，避免同名视频互相覆盖
  static String _partFileName(VideoItem item) {
    final safe = item.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '${_fnv1a(item.key)}_$safe.part';
  }

  /// 清理长期未更新的复制分片，避免失败任务无限占用磁盘。
  ///
  /// 只删除超过 [maxAge] 未修改的 `.part` 与 `.part.meta`；
  /// 正在下载的文件会被持续写入，不会被误删。
  static Future<void> cleanupStaleParts({
    Duration maxAge = const Duration(days: 7),
  }) async {
    try {
      final dir = await _downloadDir();
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.part') &&
            !entity.path.endsWith('.part.meta')) {
          continue;
        }
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) {
            await entity.delete();
          }
        } catch (_) {
          // 单个文件清理失败不影响其他文件
        }
      }
    } catch (_) {
      // 缓存目录不可用时忽略
    }
  }

  /// FNV-1a 32 位哈希，用于给分片文件名去重
  static String _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final code in value.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[index]}';
  }
}
