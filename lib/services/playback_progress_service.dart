import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 视频播放进度记忆（按视频唯一键保存毫秒位置）。
///
/// 仅在设置中选择「接续播放」时由播放页写入；切换到「从头播放」后
/// 不读取也不写入，但已保存的记录会保留，切回后仍可继续使用。
class PlaybackProgressService {
  PlaybackProgressService._();

  static final PlaybackProgressService instance = PlaybackProgressService._();

  static const String _prefsKey = 'videoProgress';

  /// 过短的位置没有记忆价值，避免开播瞬间就写入一条 0 秒记录
  static const Duration _minPosition = Duration(seconds: 1);

  final Map<String, int> _positionsMs = {};
  Timer? _flushTimer;

  /// 启动时加载一次，之后查询走内存
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is int) {
            _positionsMs[entry.key as String] = entry.value as int;
          }
        }
      }
    } catch (_) {
      // 存储损坏时按无进度处理
    }
  }

  /// 该视频上次的播放位置；没有记录时返回 null
  Duration? positionFor(String key) {
    final ms = _positionsMs[key];
    if (ms == null) return null;
    return Duration(milliseconds: ms);
  }

  /// 记录播放位置：内存即时更新，落盘做 3 秒合并写入
  void record(String key, Duration position) {
    if (position < _minPosition) return;
    final ms = position.inMilliseconds;
    if (_positionsMs[key] == ms) return;
    _positionsMs[key] = ms;
    _scheduleFlush();
  }

  /// 播放完毕时清除记录，下次从头开始
  void clear(String key) {
    if (_positionsMs.remove(key) == null) return;
    _scheduleFlush();
  }

  /// 立即把内存中的进度写入磁盘（退出播放页时调用）
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_write());
  }

  void _scheduleFlush() {
    // 不用「每次事件都重置计时」的纯防抖：播放中位置事件持续到来，
    // 防抖会永远不触发落盘。这里保证最多每 3 秒写一次。
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(seconds: 3), () {
      _flushTimer = null;
      unawaited(_write());
    });
  }

  Future<void> _write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, json.encode(_positionsMs));
    } catch (_) {
      // 写入失败不影响播放
    }
  }
}
