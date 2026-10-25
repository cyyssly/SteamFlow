import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/services/lan_protocol.dart';

/// UDP 设备发现服务。
///
/// 同时承担两件事：
///  * 广播自己的心跳（开启共享时）；
///  * 监听同一端口上其他设备的心跳与探测请求。
class LanDiscoveryService {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _beaconTimer;
  Timer? _expireTimer;

  bool _advertising = false;
  String _deviceId = '';
  String _deviceName = 'SteamFlow';
  int _httpPort = LanProtocol.defaultHttpPort;
  int _folderCount = 0;

  final Map<String, LanDevice> _devices = {};

  /// 收到某台设备的心跳（新增或刷新）
  void Function(LanDevice device)? onDeviceUpdated;

  /// 某台设备超时离线
  void Function(String deviceId)? onDeviceLost;

  bool get isRunning => _socket != null;

  /// 启动监听。端口只绑定一次，之后通过 [setAdvertising] 控制是否广播。
  Future<void> start({
    required String deviceId,
    required String deviceName,
  }) async {
    if (_socket != null) return;
    _deviceId = deviceId;
    _deviceName = deviceName;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LanProtocol.discoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _subscription = socket.listen(_handleEvent);
    _expireTimer = Timer.periodic(
      LanProtocol.beaconInterval,
      (_) => _removeStaleDevices(),
    );
    sendProbe();
  }

  /// 开关本机广播，并同步当前 HTTP 端口与共享目录数量。
  void setAdvertising({
    required bool enabled,
    required int port,
    required int folderCount,
  }) {
    _advertising = enabled;
    _httpPort = port;
    _folderCount = folderCount;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (!enabled) return;
    _sendBeacon();
    _beaconTimer = Timer.periodic(
      LanProtocol.beaconInterval,
      (_) => _sendBeacon(),
    );
  }

  /// 立即询问局域网内有哪些设备在线（用于进入页面时快速刷新）
  void sendProbe() {
    _send({
      'type': LanProtocol.probeType,
      'v': LanProtocol.version,
      'id': _deviceId,
    });
  }

  void _sendBeacon({InternetAddress? target, int? targetPort}) {
    if (!_advertising) return;
    final message = <String, Object?>{
      'type': LanProtocol.beaconType,
      'v': LanProtocol.version,
      'id': _deviceId,
      'name': _deviceName,
      'port': _httpPort,
      'folders': _folderCount,
    };
    _send(message, target: target, targetPort: targetPort);
  }

  void _send(
    Map<String, Object?> message, {
    InternetAddress? target,
    int? targetPort,
  }) {
    final socket = _socket;
    if (socket == null) return;
    try {
      final bytes = utf8.encode(jsonEncode(message));
      socket.send(
        bytes,
        target ?? InternetAddress('255.255.255.255'),
        targetPort ?? LanProtocol.discoveryPort,
      );
    } catch (_) {
      // 网络切换、接口不可用等情况下发送失败属正常，等待下一次心跳
    }
  }

  void _handleEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    // 一次读事件可能对应多个已排队的报文，必须全部取出
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) break;
      _handleDatagram(datagram);
    }
  }

  void _handleDatagram(Datagram datagram) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(
        utf8.decode(datagram.data, allowMalformed: true),
      );
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } catch (_) {
      return;
    }

    if (message['v'] != LanProtocol.version) return;
    final type = message['type'];
    if (type == LanProtocol.beaconType) {
      _handleBeacon(message, datagram.address);
    } else if (type == LanProtocol.probeType && _advertising) {
      // 收到探测：直接单播回复，避免对方等下一个心跳周期
      _sendBeacon(target: datagram.address, targetPort: datagram.port);
    }
  }

  void _handleBeacon(Map<String, dynamic> message, InternetAddress address) {
    final id = message['id'];
    if (id is! String || id.isEmpty || id == _deviceId) return;
    final port = message['port'];
    if (port is! int || port <= 0) return;

    final device = LanDevice(
      id: id,
      name: (message['name'] as String?)?.trim().isNotEmpty == true
          ? message['name'] as String
          : 'SteamFlow',
      host: address.address,
      port: port,
      folderCount: message['folders'] is int ? message['folders'] as int : 0,
      lastSeen: DateTime.now(),
    );
    _devices[id] = device;
    onDeviceUpdated?.call(device);
  }

  void _removeStaleDevices() {
    final now = DateTime.now();
    final expired = _devices.entries
        .where(
          (entry) =>
              now.difference(entry.value.lastSeen) > LanProtocol.deviceTimeout,
        )
        .map((entry) => entry.key)
        .toList();
    for (final id in expired) {
      _devices.remove(id);
      onDeviceLost?.call(id);
    }
  }

  Future<void> close() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _expireTimer?.cancel();
    _expireTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _devices.clear();
  }
}
