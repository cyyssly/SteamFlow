import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每个视频的播放偏好记忆（音轨 / 字幕 / 横竖屏状态）。
///
/// 用户在右键菜单里切换过某个视频的默认音轨或字幕后，下次再播放
/// 同一视频会自动应用用户上次选的轨道。若用户偏好的轨道已不存在
/// （视频文件被替换 / 内嵌轨道结构变化），则静默回退到 auto。
/// 移动端在播放页里手动切过横竖屏后，也会记住该视频的方向，
/// 下次播放同一视频时自动恢复。
class TrackPrefService {
  TrackPrefService._();
  static final TrackPrefService instance = TrackPrefService._();

  static const String _prefsKey = 'videoTrackPrefs';

  final Map<String, _TrackPref> _prefs = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String && entry.value is Map) {
            final v = entry.value as Map;
            _prefs[entry.key as String] = _TrackPref(
              audioId: v['audio'] as String?,
              subtitleId: v['subtitle'] as String?,
              orientation: v['orientation'] as String?,
            );
          }
        }
      }
    } catch (_) {
      // 存储损坏时按无偏好处理
    }
  }

  /// 该视频上次保存的音轨 / 字幕偏好；没有记录时返回 null
  String? audioIdFor(String path) => _prefs[path]?.audioId;
  String? subtitleIdFor(String path) => _prefs[path]?.subtitleId;

  /// 该视频上次手动锁定的屏幕方向（'landscape' / 'portrait'）；
  /// null 表示没手动切过，播放时跟随设置里的方向偏好。
  String? orientationFor(String path) => _prefs[path]?.orientation;

  /// 用户切换音轨/字幕后写入内存，立即落盘（轨道变化频率极低，无需合并）
  Future<void> save(
    String path, {
    String? audioId,
    String? subtitleId,
    String? orientation,
  }) async {
    final existing = _prefs[path];
    final updated = _TrackPref(
      audioId: audioId ?? existing?.audioId,
      subtitleId: subtitleId ?? existing?.subtitleId,
      orientation: orientation ?? existing?.orientation,
    );
    if (updated.audioId == existing?.audioId &&
        updated.subtitleId == existing?.subtitleId &&
        updated.orientation == existing?.orientation) {
      return; // 无变化，不写盘
    }
    // auto / no 是系统默认值，没必要存（下次不存时播放器自动用 auto）
    final filteredIds = updated._filtered();
    if (filteredIds.audioId == null &&
        filteredIds.subtitleId == null &&
        filteredIds.orientation == null) {
      _prefs.remove(path);
    } else {
      _prefs[path] = filteredIds;
    }
    await _write();
  }

  /// 在 tracks 事件触发时调用：如果当前视频存过偏好，并且偏好的轨道
  /// 确实存在于 tracks 里，就应用；否则静默跳过（播放器保持 auto）。
  void applyPrefsIfMatched({
    required String videoKey,
    required Tracks tracks,
    required Player player,
  }) {
    final pref = _prefs[videoKey];
    if (pref == null) return;

    if (pref.audioId != null) {
      final match = tracks.audio.where((t) => t.id == pref.audioId);
      if (match.isNotEmpty) {
        unawaited(player.setAudioTrack(match.first).catchError((_) {}));
      }
    }

    if (pref.subtitleId != null) {
      final match = tracks.subtitle.where((t) => t.id == pref.subtitleId);
      if (match.isNotEmpty) {
        unawaited(player.setSubtitleTrack(match.first).catchError((_) {}));
      }
    }
  }

  Future<void> _write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, Map<String, String>>{};
      for (final entry in _prefs.entries) {
        final inner = <String, String>{};
        if (entry.value.audioId != null) inner['audio'] = entry.value.audioId!;
        if (entry.value.subtitleId != null) {
          inner['subtitle'] = entry.value.subtitleId!;
        }
        if (entry.value.orientation != null) {
          inner['orientation'] = entry.value.orientation!;
        }
        if (inner.isNotEmpty) map[entry.key] = inner;
      }
      await prefs.setString(_prefsKey, json.encode(map));
    } catch (_) {
      // 写入失败不影响播放
    }
  }
}

class _TrackPref {
  final String? audioId;
  final String? subtitleId;

  /// 移动端手动锁定的屏幕方向：'landscape' / 'portrait'。
  final String? orientation;
  const _TrackPref({this.audioId, this.subtitleId, this.orientation});

  /// 过滤掉播放器默认值：音频的 auto / no 不是菜单里的可选项，存了没意义；
  /// 字幕的 `no` 表示用户主动关闭字幕，需要记住。
  _TrackPref _filtered() {
    String? a = audioId;
    String? s = subtitleId;
    if (a == 'auto' || a == 'no') a = null;
    if (s == 'auto') s = null;
    return _TrackPref(audioId: a, subtitleId: s, orientation: orientation);
  }
}
