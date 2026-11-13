import 'package:flutter/material.dart';

import 'package:steam_flow/l10n/app_localizations.dart';

/// 同名文件冲突的用户选择
enum CopyConflictChoice { replaceAll, skipAll, replaceOne, skipOne, cancel }

/// 一批复制/移动的同名冲突处理结果
class CopyConflictPlan {
  const CopyConflictPlan({
    required this.replace,
    required this.skip,
    required this.cancelled,
  });

  /// 需要覆盖写入的文件名
  final Set<String> replace;

  /// 需要跳过的文件名
  final Set<String> skip;

  /// 用户是否取消了整个操作
  final bool cancelled;
}

/// 复制 / 移动时的同名文件冲突处理，已排除页与远端复制共用。
class CopyConflictService {
  CopyConflictService._();

  /// 统计本次写入中与目标同名的文件，并让用户决定替换或跳过。
  ///
  /// [names] 为本次要写入的文件名（按写入顺序），[existing] 为目标目录
  /// 中已存在的文件名。批量操作时 [batch] 为 true，弹窗会给出同名文件
  /// 数量，并提供「全部替换 / 全部跳过 / 替换本文件 / 跳过本文件 / 取消」；
  /// 同一批内出现多次的文件名同样按冲突处理，否则后一个会覆盖前一个。
  static Future<CopyConflictPlan> resolveConflicts(
    BuildContext context, {
    required String title,
    required List<String> names,
    required Set<String> existing,
    required bool batch,
  }) async {
    final loc = AppLocalizations.of(context);
    final counts = <String, int>{};
    for (final name in names) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final conflicts = [
      for (final entry in counts.entries)
        if (existing.contains(entry.key) || entry.value > 1) entry.key,
    ];
    if (conflicts.isEmpty) {
      return const CopyConflictPlan(replace: {}, skip: {}, cancelled: false);
    }

    final conflicting = conflicts.fold<int>(
      0,
      (sum, name) => sum + (counts[name] ?? 0),
    );
    var replaceAll = false;
    var skipAll = false;
    final replace = <String>{};
    final skip = <String>{};

    for (final name in conflicts) {
      if (replaceAll) {
        replace.add(name);
        continue;
      }
      if (skipAll) {
        skip.add(name);
        continue;
      }
      if (!context.mounted) {
        return CopyConflictPlan(replace: replace, skip: skip, cancelled: true);
      }
      final choice = await showDialog<CopyConflictChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF16213e),
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                batch
                    ? loc.conflictBatch(conflicting, names.length)
                    : loc.conflictSingle(name),
              ),
              if (batch) ...[
                const SizedBox(height: 8),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ],
          ),
          actions: batch
              ? [
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.cancel),
                    child: Text(loc.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipAll),
                    child: Text(loc.skipAll),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceAll),
                    child: Text(loc.replaceAll),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipOne),
                    child: Text(loc.skipThis),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceOne),
                    child: Text(loc.replaceThis),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.cancel),
                    child: Text(loc.cancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.skipOne),
                    child: Text(loc.skipFile),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(
                      dialogContext,
                    ).pop(CopyConflictChoice.replaceOne),
                    child: Text(loc.replaceFile),
                  ),
                ],
        ),
      );
      switch (choice) {
        case CopyConflictChoice.replaceAll:
          replaceAll = true;
          replace.add(name);
          break;
        case CopyConflictChoice.skipAll:
          skipAll = true;
          skip.add(name);
          break;
        case CopyConflictChoice.replaceOne:
          replace.add(name);
          break;
        case CopyConflictChoice.skipOne:
          skip.add(name);
          break;
        case CopyConflictChoice.cancel:
        case null:
          return CopyConflictPlan(
            replace: replace,
            skip: skip,
            cancelled: true,
          );
      }
    }
    return CopyConflictPlan(replace: replace, skip: skip, cancelled: false);
  }
}
