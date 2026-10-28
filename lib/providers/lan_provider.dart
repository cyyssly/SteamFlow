import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/services/lan_client_service.dart';
import 'package:steam_flow/utils/filename_compare.dart';
import 'package:steam_flow/services/lan_discovery_service.dart';
import 'package:steam_flow/services/lan_protocol.dart';
import 'package:steam_flow/services/lan_server_service.dart';

/// 局域网相关的错误状态，由界面翻译成对应文案
enum LanError { none, invalidAddress, selfDevice, serverStartFailed }

/// 局域网共享的状态中枢。
///
/// 同时管理两件事：
///  * 作为主机：按设置启动 HTTP 服务并广播心跳；
///  * 作为客户端：通过 UDP 发现设备，并保存手动添加的地址。
class LanProvider extends ChangeNotifier with WidgetsBindingObserver {
  LanProvider({
    required SettingsProvider settings,
    required SlideProvider slide,
  }) : _settings = settings,
       _slide = slide {
    _appliedFolders = List.of(slide.folderPaths);
    _appliedShareEnabled = settings.lanShareEnabled;
    _appliedRecursiveScan = settings.recursiveScan;
    _appliedSharingMap = Map.of(settings.lanFolderSharing);
    _appliedSharedKeys = [for (final ref in settings.sharedFolders) ref.key];
  }

  final SettingsProvider _settings;
  final SlideProvider _slide;
  final LanDiscoveryService _discovery = LanDiscoveryService();
  final LanServerService _server = LanServerService.instance;

  final Map<String, LanDevice> _discovered = {};
  final List<LanDevice> _manual = [];

  bool _initialized = false;
  bool _disposed = false;
  bool _discoveryAvailable = false;
  bool _discoveryPaused = false;
  Future<void>? _pauseFuture;
  bool _sharing = false;
  LanError _error = LanError.none;
  List<String> _localAddresses = const [];
  bool _syncing = false;
  bool _syncPending = false;

  List<String> _appliedFolders = const [];
  bool _appliedShareEnabled = false;
  bool _appliedRecursiveScan = true;
  Map<String, bool> _appliedSharingMap = const {};

  /// 共享源设备的可达状态（deviceId -> 是否可连接）
  final Map<String, bool> _reachable = {};

  /// 正在探测的设备，避免同一设备并发探测
  final Set<String> _probing = {};

  /// 共享文件夹封面缩略图地址（ref.key -> 缩略图 URL）
  final Map<String, String?> _folderCovers = {};

  /// 远端设备允许的操作（deviceId -> 能力），未探测到前一律视为不支持
  final Map<String, RemoteCapabilities> _capabilities = {};

  /// 离线共享源的自动重连计时器
  Timer? _reconnectTimer;

  /// 上次已应用的共享源标识，用于检测「添加/移除共享源」
  List<String> _appliedSharedKeys = const [];

  /// 最近被本机排除的远端视频（deviceId -> remoteId 集合）。
  ///
  /// 播放页远程排除后，远端瀑布流在返回时据此立即隐藏该条目，
  /// 不必整页重新拉取列表（也就能保留当前滚动位置）。
  final Map<String, Set<String>> _recentlyExcludedRemote = {};

  /// 正在获取封面的文件夹，避免并发重复请求
  final Set<String> _coverLoading = {};

  /// 获取封面失败的文件夹，等待手动刷新后再重试
  final Set<String> _coverFailed = {};

  /// 封面缩略图的磁盘缓存路径（ref.key -> 本地文件路径）
  final Map<String, String> _coverFiles = {};

  /// 封面缓存目录，首次使用时创建
  Directory? _coverDir;

  /// 当前可用的设备（发现到的 + 手动添加的）
  List<LanDevice> get devices {
    final merged = <String, LanDevice>{};
    for (final device in _discovered.values) {
      merged['${device.host}:${device.port}'] = device;
    }
    // 手动设备与自动发现重复时，优先使用自动发现的实时信息
    for (final device in _manual) {
      merged.putIfAbsent('${device.host}:${device.port}', () => device);
    }
    final list = merged.values.toList()
      ..sort((a, b) => compareFileNames(a.name, b.name));
    return list;
  }

  /// 本机是否正在提供共享服务
  bool get isSharing => _sharing;

  /// 共享服务的端口（未启动时为默认端口）
  int get sharePort => _server.port;

  /// 本机在局域网中的访问地址
  List<String> get localAddresses => _localAddresses;

  /// UDP 发现是否可用（部分网络环境可能禁止广播）
  bool get discoveryAvailable => _discoveryAvailable;

  LanError get error => _error;

  /// 本机当前勾选为共享的文件夹（全局共享关闭时仍返回勾选结果）
  List<String> get sharedLocalFolders {
    return [
      for (final path in _slide.folderPaths)
        if (_settings.isLocalFolderShared(path)) path,
    ];
  }

  /// 按设备标识查找当前在线（已发现或手动添加）的设备
  LanDevice? deviceById(String id) {
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// 解析共享文件夹所属设备：优先使用实时发现到的地址，
  /// 设备未发现时回退到持久化记录中的地址，便于尝试重连。
  LanDevice resolveDevice(SharedFolderRef ref) {
    final device = deviceById(ref.deviceId);
    if (device != null) return device;
    return LanDevice(
      id: ref.deviceId,
      name: ref.deviceName,
      host: ref.host,
      port: ref.port,
      folderCount: 0,
      lastSeen: DateTime.now(),
      manual: true,
    );
  }

  bool isDeviceReachable(String deviceId) => _reachable[deviceId] ?? false;

  /// 记录一条已成功请求远端排除的视频
  void markRemoteExcluded(String deviceId, String remoteId) {
    if (deviceId.isEmpty || remoteId.isEmpty) return;
    (_recentlyExcludedRemote[deviceId] ??= <String>{}).add(remoteId);
  }

  /// 该远端视频是否已被本次会话排除
  bool isRemoteExcluded(String deviceId, String remoteId) =>
      _recentlyExcludedRemote[deviceId]?.contains(remoteId) ?? false;

  /// 列表重新拉取后清空记录（服务端已同步排除，不再需要本地提示）
  void clearRemoteExcluded(String deviceId) {
    _recentlyExcludedRemote.remove(deviceId);
  }

  /// 远端设备允许的操作；未探测到时视为全部不支持
  RemoteCapabilities capabilitiesFor(String deviceId) =>
      _capabilities[deviceId] ?? RemoteCapabilities.none;

  /// 主动刷新某台设备的能力，返回最新结果
  Future<RemoteCapabilities> refreshCapabilities(LanDevice device) async {
    final info = await LanClientService.instance.fetchInfo(device);
    if (info != null) {
      _updateCapabilities(device.id, info);
      if (!_disposed) notifyListeners();
    }
    return capabilitiesFor(device.id);
  }

  void _updateCapabilities(String deviceId, Map<String, dynamic> info) {
    final caps = RemoteCapabilities(
      exclude: info['rx'] == true,
      copy: info['rc'] == true,
    );
    final current = _capabilities[deviceId];
    if (current != null &&
        current.exclude == caps.exclude &&
        current.copy == caps.copy) {
      return;
    }
    _capabilities[deviceId] = caps;
  }

  /// 共享文件夹的封面缩略图地址，尚未取回时为 null
  String? coverUrlFor(String folderKey) => _folderCovers[folderKey];

  /// 共享文件夹封面的本地缓存文件，离线时优先用它显示
  String? coverFileFor(String folderKey) => _coverFiles[folderKey];

  /// 并行探测共享源设备是否在线，用于界面显示离线灰态
  Future<void> probeSharedDevices(List<SharedFolderRef> refs) async {
    final seen = <String>{};
    final futures = <Future<void>>[];
    for (final ref in refs) {
      if (!seen.add(ref.deviceId)) continue;
      futures.add(_probeDevice(ref));
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
    if (!_disposed) notifyListeners();
  }

  Future<void> _probeDevice(SharedFolderRef ref) async {
    if (!_probing.add(ref.deviceId)) return;
    try {
      final info = await LanClientService.instance.fetchInfo(
        resolveDevice(ref),
      );
      _reachable[ref.deviceId] = info != null;
      if (info != null) _updateCapabilities(ref.deviceId, info);
    } finally {
      _probing.remove(ref.deviceId);
    }
  }

  /// 重新连接单个共享文件夹，并同步最新的文件夹名称与视频数量
  Future<bool> refreshSharedFolder(SharedFolderRef ref) async {
    final ok = await _refreshSharedFolder(ref);
    if (ok) {
      // 显式重连时允许重新尝试之前取封面失败的文件夹
      _coverFailed.remove(ref.key);
      await _loadCover(ref);
    }
    if (!_disposed) notifyListeners();
    return ok;
  }

  /// 重新连接全部共享源（同一设备只请求一次）
  Future<void> refreshSharedFolders(List<SharedFolderRef> refs) async {
    final seen = <String>{};
    final futures = <Future<void>>[];
    for (final ref in refs) {
      if (!seen.add(ref.deviceId)) continue;
      futures.add(_refreshSharedFolder(ref));
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
    await Future.wait([for (final ref in refs) _loadCover(ref)]);
    if (!_disposed) notifyListeners();
  }

  Future<bool> _refreshSharedFolder(SharedFolderRef ref) async {
    final device = resolveDevice(ref);
    // 先做一次轻量的在线确认：真正掉线时 4 秒内即可失败，
    // 不必把文件夹列表的长超时等满
    final info = await LanClientService.instance.fetchInfo(device);
    if (info == null) {
      _reachable[ref.deviceId] = false;
      return false;
    }
    _reachable[ref.deviceId] = true;
    _updateCapabilities(ref.deviceId, info);
    final folders = await LanClientService.instance.fetchFolders(device);
    if (folders == null) return false;

    RemoteFolder? match;
    for (final folder in folders) {
      if (folder.id == ref.folderId) {
        match = folder;
        break;
      }
    }
    _settings.updateSharedFolder(
      ref.copyWith(
        deviceName: device.name,
        host: device.host,
        port: device.port,
        folderName: match?.name,
        videoCount: match?.videoCount,
      ),
    );
    return match != null;
  }

  /// 读取共享文件夹的全部视频元数据，失败时返回 null
  Future<List<VideoItem>?> loadSharedFolderVideos(SharedFolderRef ref) async {
    final device = resolveDevice(ref);
    // 先快速确认设备是否在线：真正掉线时几秒内返回，
    // 在线后再按长超时等待大目录扫描完成
    final info = await LanClientService.instance.fetchInfo(device);
    if (info == null) {
      _reachable[ref.deviceId] = false;
      if (!_disposed) notifyListeners();
      return null;
    }
    _reachable[ref.deviceId] = true;
    _updateCapabilities(ref.deviceId, info);
    final videos = await LanClientService.instance.fetchAllVideos(
      device,
      folderId: ref.folderId,
    );
    if (!_disposed) notifyListeners();
    return videos;
  }

  /// 离线共享源的自动重连：有离线源时每 15 秒重试一次，全部在线后停止。
  ///
  /// 只针对已添加的共享文件夹；设备发现本身靠 UDP 心跳，不在这里轮询。
  void _ensureReconnectCycle() {
    final refs = _settings.sharedFolders;
    final hasOffline = refs.any((ref) => !isDeviceReachable(ref.deviceId));
    if (!hasOffline) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }
    _reconnectTimer ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_retryOfflineSources()),
    );
  }

  Future<void> _retryOfflineSources() async {
    if (_disposed) return;
    final refs = _settings.sharedFolders;
    final offline = [
      for (final ref in refs)
        if (!isDeviceReachable(ref.deviceId)) ref,
    ];
    if (offline.isEmpty) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }
    await probeSharedDevices(offline);
    if (_disposed) return;
    final pending = [
      for (final ref in offline)
        if (isDeviceReachable(ref.deviceId)) ref,
    ];
    if (pending.isNotEmpty) {
      await refreshSharedFolders(pending);
      if (_disposed) return;
      await loadSharedFolderCovers(pending);
    }
    _ensureReconnectCycle();
  }

  /// 为在线的共享文件夹取回第一个视频的缩略图作为封面
  Future<void> loadSharedFolderCovers(List<SharedFolderRef> refs) async {
    final futures = <Future<void>>[];
    for (final ref in refs) {
      // 已有缓存或已失败过的文件夹不再重复请求
      if (_coverFiles.containsKey(ref.key)) continue;
      if (_coverFailed.contains(ref.key)) continue;
      if (!isDeviceReachable(ref.deviceId)) continue;
      futures.add(_loadCover(ref));
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadCover(SharedFolderRef ref) async {
    if (!isDeviceReachable(ref.deviceId)) return;
    if (!_coverLoading.add(ref.key)) return;
    try {
      final page = await LanClientService.instance.fetchVideos(
        resolveDevice(ref),
        folderId: ref.folderId,
        limit: 1,
      );
      final items = page?.items;
      final cover = items != null && items.isNotEmpty
          ? items.first.thumbUrl
          : null;
      if (cover != null) {
        _folderCovers[ref.key] = cover;
        await _saveCover(ref, cover);
      } else {
        _coverFailed.add(ref.key);
      }
    } finally {
      _coverLoading.remove(ref.key);
    }
  }

  /// 把封面缩略图落盘，供设备离线或应用重启后继续显示
  Future<void> _saveCover(SharedFolderRef ref, String url) async {
    final bytes = await LanClientService.instance.fetchBytes(url);
    if (bytes == null || bytes.isEmpty) return;
    try {
      final dir = await _ensureCoverDir();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_coverFileName(ref.key)}',
      );
      // 先写临时文件再改名，避免中断时留下半张图片
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      // 同一路径内容已更新，需清掉旧的解码缓存
      await FileImage(file).evict();
      _coverFiles[ref.key] = file.path;
    } catch (_) {
      // 缓存失败不影响在线显示
    }
  }

  Future<Directory> _ensureCoverDir() async {
    final cached = _coverDir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}steam_flow_covers',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _coverDir = dir;
  }

  /// folderKey 含 `/` 等字符，转换为安全的缓存文件名
  String _coverFileName(String key) =>
      '${key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.thumb';

  /// 启动时把已存在的封面缓存路径装载到内存，便于离线时直接显示
  Future<void> _loadCoverFiles() async {
    try {
      final dir = await _ensureCoverDir();
      for (final ref in _settings.sharedFolders) {
        final file = File(
          '${dir.path}${Platform.pathSeparator}${_coverFileName(ref.key)}',
        );
        if (await file.exists()) {
          _coverFiles[ref.key] = file.path;
        }
      }
      if (!_disposed && _coverFiles.isNotEmpty) notifyListeners();
    } catch (_) {
      // 缓存目录不可用时忽略，回退到在线加载
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _discovery.onDeviceUpdated = (device) {
      final previous = _discovered[device.id];
      _discovered[device.id] = device;
      _reachable[device.id] = true;
      // 心跳每 3 秒刷新一次 lastSeen，可见信息没变时不必触发整页重建
      if (previous == null ||
          previous.name != device.name ||
          previous.host != device.host ||
          previous.port != device.port ||
          previous.folderCount != device.folderCount) {
        notifyListeners();
      }
    };
    _discovery.onDeviceLost = (id) {
      if (_discovered.remove(id) != null) notifyListeners();
    };

    try {
      await _discovery.start(
        deviceId: _settings.deviceId,
        deviceName: _settings.deviceName,
      );
      _discoveryAvailable = true;
    } catch (_) {
      _discoveryAvailable = false;
    }

    _settings.addListener(_onSettingsChanged);
    _slide.addListener(_onSlideChanged);
    WidgetsBinding.instance.addObserver(this);

    unawaited(_loadLocalAddresses());
    unawaited(_loadCoverFiles());
    await _syncSharing();
    _ensureReconnectCycle();
  }

  /// 重新探测局域网设备，并刷新手动设备的在线信息
  Future<void> refresh() async {
    _discovery.sendProbe();
    notifyListeners();
    await _refreshManualDevices();
  }

  /// 移动端退到后台时暂停 UDP 发现，避免广播包持续唤醒 Wi-Fi 与 CPU。
  ///
  /// 桌面端不受影响：窗口失焦不会进入 paused，且没有省电需求。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized || !_discoveryAvailable) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_pauseDiscovery());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_resumeDiscovery());
    }
  }

  Future<void> _pauseDiscovery() {
    if (!_discoveryPaused) {
      _discoveryPaused = true;
      _pauseFuture = _closeDiscovery();
    }
    return _pauseFuture ?? Future<void>.value();
  }

  Future<void> _closeDiscovery() async {
    // close() 同时会取消心跳定时器，后台不再发送广播
    await _discovery.close();
    // 服务端已清空自己的设备表，这里同步清掉界面数据，避免恢复后残留离线设备
    if (!_disposed && _discovered.isNotEmpty) {
      _discovered.clear();
      notifyListeners();
    }
  }

  Future<void> _resumeDiscovery() async {
    if (!_discoveryPaused) return;
    _discoveryPaused = false;
    // 等待后台暂停时的 close 真正完成，避免新 socket 与旧 socket 绑定竞争
    await _pauseFuture;
    if (_disposed || _discoveryPaused) return;
    try {
      await _discovery.start(
        deviceId: _settings.deviceId,
        deviceName: _settings.deviceName,
      );
      // start() 会立即探测一次；若正在共享，需恢复广播与外网可见性
      _discovery.setAdvertising(
        enabled: _sharing,
        port: _sharing ? _server.port : 0,
        folderCount: _sharing ? sharedLocalFolders.length : 0,
      );
    } catch (_) {
      _discoveryAvailable = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 添加一个手动地址，支持 `IP` 或 `IP:端口`
  Future<LanDevice?> addManualDevice(String input) async {
    _setError(LanError.none);
    final parsed = _parseAddress(input);
    if (parsed == null) {
      _setError(LanError.invalidAddress);
      return null;
    }

    final probe = LanDevice(
      id: 'manual:${parsed.host}:${parsed.port}',
      name: parsed.host,
      host: parsed.host,
      port: parsed.port,
      folderCount: 0,
      lastSeen: DateTime.now(),
      manual: true,
    );
    final info = await LanClientService.instance.fetchInfo(probe);
    if (info == null) {
      _setError(LanError.invalidAddress);
      return null;
    }

    final remoteId = info['id'];
    if (remoteId is String && remoteId == _settings.deviceId) {
      _setError(LanError.selfDevice);
      return null;
    }

    final device = LanDevice(
      id: remoteId is String && remoteId.isNotEmpty ? remoteId : probe.id,
      name: (info['name'] as String?)?.trim().isNotEmpty == true
          ? info['name'] as String
          : parsed.host,
      host: parsed.host,
      port: parsed.port,
      folderCount: info['folders'] is int ? info['folders'] as int : 0,
      lastSeen: DateTime.now(),
      manual: true,
    );
    _manual
      ..removeWhere(
        (item) => item.host == device.host && item.port == device.port,
      )
      ..add(device);
    _reachable[device.id] = true;
    _updateCapabilities(device.id, info);
    _setError(LanError.none);
    notifyListeners();
    return device;
  }

  void removeManualDevice(LanDevice device) {
    _manual.removeWhere(
      (item) =>
          item.id == device.id &&
          item.host == device.host &&
          item.port == device.port,
    );
    notifyListeners();
  }

  /// 关闭或重启共享服务
  Future<void> _syncSharing() async {
    if (_syncing) {
      _syncPending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncPending = false;
        await _applySharing();
      } while (_syncPending);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _applySharing() async {
    final enabled = _settings.lanShareEnabled;
    final folders = sharedLocalFolders;

    if (enabled && folders.isNotEmpty) {
      try {
        await _server.start(
          deviceId: _settings.deviceId,
          deviceName: _settings.deviceName,
          folderPaths: () => sharedLocalFolders,
          recursiveScan: () => _settings.recursiveScan,
          excludedPaths: () => _settings.excludedPaths,
          remoteExcludeEnabled: () => _settings.allowRemoteExclude,
          remoteCopyEnabled: () => _settings.allowRemoteCopy,
          onExcludedPath: _settings.addExcludedPath,
        );
        _sharing = true;
        if (_error == LanError.serverStartFailed) {
          _error = LanError.none;
        }
      } catch (_) {
        _sharing = false;
        _error = LanError.serverStartFailed;
      }
    } else {
      await _server.stop();
      _sharing = false;
      if (_error == LanError.serverStartFailed) {
        _error = LanError.none;
      }
    }

    _discovery.setAdvertising(
      enabled: _sharing,
      port: _sharing ? _server.port : 0,
      folderCount: _sharing ? folders.length : 0,
    );
    notifyListeners();
  }

  void _onSettingsChanged() {
    final enabled = _settings.lanShareEnabled;
    final recursive = _settings.recursiveScan;
    final sharingMap = _settings.lanFolderSharing;
    final sharedKeys = [for (final ref in _settings.sharedFolders) ref.key];
    final sourcesChanged = !listEquals(sharedKeys, _appliedSharedKeys);
    if (sourcesChanged) {
      _appliedSharedKeys = sharedKeys;
      _ensureReconnectCycle();
    }
    if (enabled == _appliedShareEnabled &&
        recursive == _appliedRecursiveScan &&
        mapEquals(sharingMap, _appliedSharingMap)) {
      return;
    }
    _appliedShareEnabled = enabled;
    _appliedRecursiveScan = recursive;
    _appliedSharingMap = Map.of(sharingMap);
    unawaited(_syncSharing());
  }

  void _onSlideChanged() {
    final folders = _slide.folderPaths;
    if (listEquals(folders, _appliedFolders)) return;
    _appliedFolders = List.of(folders);
    unawaited(_syncSharing());
  }

  Future<void> _refreshManualDevices() async {
    if (_manual.isEmpty) return;
    for (var i = 0; i < _manual.length; i++) {
      final device = _manual[i];
      final info = await LanClientService.instance.fetchInfo(device);
      if (info == null) continue;
      _manual[i] = device.copyWith(
        name: (info['name'] as String?)?.trim().isNotEmpty == true
            ? info['name'] as String
            : device.name,
        folderCount: info['folders'] is int
            ? info['folders'] as int
            : device.folderCount,
        lastSeen: DateTime.now(),
      );
      _updateCapabilities(device.id, info);
    }
    notifyListeners();
  }

  Future<void> _loadLocalAddresses() async {
    // 一个终端只对外暴露一个地址：优先 192.168.x.x，
    // 没有时才回退到其他地址，避免界面上出现多行地址
    String? preferred;
    final fallbacks = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (_isLanIpv4(ip)) {
            preferred ??= ip;
          } else if (!fallbacks.contains(ip)) {
            fallbacks.add(ip);
          }
        }
      }
    } catch (_) {
      // 读取失败时仅显示回环地址
    }
    _localAddresses = [preferred ?? (fallbacks.firstOrNull ?? '127.0.0.1')];
    if (!_disposed) notifyListeners();
  }

  /// 是否为家用/办公局域网常见的 192.168.x.x 地址
  ///
  /// 手机上的 10.x（蜂窝数据）与 172.16–31.x（容器/VPN）虽然也是私有地址，
  /// 但通常不是其他终端可直接访问的本机地址，这里一并过滤掉。
  static bool _isLanIpv4(String ip) =>
      ip.startsWith('192.168.') && ip.split('.').length == 4;

  void _setError(LanError error) {
    _error = error;
    notifyListeners();
  }

  static _ParsedAddress? _parseAddress(String input) {
    var value = input.trim();
    if (value.isEmpty) return null;
    value = value.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    value = value.split('/').first;

    var host = value;
    var port = LanProtocol.defaultHttpPort;
    final colon = value.lastIndexOf(':');
    if (colon > 0) {
      host = value.substring(0, colon);
      final parsedPort = int.tryParse(value.substring(colon + 1));
      if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
        return null;
      }
      port = parsedPort;
    }
    if (host.isEmpty || host.contains(' ')) return null;
    return _ParsedAddress(host, port);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    _settings.removeListener(_onSettingsChanged);
    _slide.removeListener(_onSlideChanged);
    unawaited(_server.stop());
    unawaited(_discovery.close());
    LanClientService.instance.close();
    super.dispose();
  }
}

class _ParsedAddress {
  final String host;
  final int port;

  const _ParsedAddress(this.host, this.port);
}
