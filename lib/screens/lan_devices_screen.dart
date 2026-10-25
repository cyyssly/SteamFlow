import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';

/// 提示类信息的统一强调色
const Color _hintColor = Color(0xFFfdcb6e);

/// 内网共享页：只负责把本机已选文件夹共享给其他设备。
///
/// 添加其他设备的共享文件夹入口在「选择文件夹」页的“添加共享源”。
class LanDevicesScreen extends StatefulWidget {
  const LanDevicesScreen({super.key});

  @override
  State<LanDevicesScreen> createState() => _LanDevicesScreenState();
}

class _LanDevicesScreenState extends State<LanDevicesScreen> {
  /// 仅移动端需要保持常亮：页面停留期间可能随时响应其他设备的读取请求
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (_isMobile) {
      WakelockPlus.enable();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<LanProvider>(context, listen: false).refresh();
    });
  }

  @override
  void dispose() {
    if (_isMobile) {
      WakelockPlus.disable();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final lan = context.watch<LanProvider>();
    final settings = context.watch<SettingsProvider>();
    final slide = context.watch<SlideProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.lanSharePageTitle),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
      ),
      body: ListView(
        // 显式清零：ListView 默认会叠加系统安全区横向内边距，
        // 会把下方文件夹开关整体往中间推，导致与卡片开关错位
        padding: EdgeInsets.zero,
        children: [
          _buildShareCard(loc, lan, settings, slide.folderPaths),
          if (_isMobile)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                children: [
                  _hintRow(Icons.light_mode, loc.lanShareKeepAwakeHint),
                  const SizedBox(height: 6),
                  _hintRow(Icons.battery_alert, loc.lanShareBatteryHint),
                ],
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              loc.localFoldersSection,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          for (final path in slide.folderPaths)
            SwitchListTile(
              key: ValueKey('share-$path'),
              // 与上方卡片开关使用同一水平内边距，保证开关竖向对齐
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              secondary: const Icon(
                Icons.folder_open,
                color: Color(0xFF0984e3),
              ),
              title: Text(
                Platform.isAndroid ? _lastSegment(path) : path,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                loc.lanShareFolderSwitchHint,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              activeThumbColor: const Color(0xFFe94560),
              value: settings.isLocalFolderShared(path),
              onChanged: (value) => settings.setLanFolderShared(path, value),
            ),
        ],
      ),
    );
  }

  Widget _buildShareCard(
    AppLocalizations loc,
    LanProvider lan,
    SettingsProvider settings,
    List<String> folderPaths,
  ) {
    return Padding(
      // 不再使用卡片底色，仅保留上下留白
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(Icons.wifi_tethering),
            title: Text(loc.lanShareTitle),
            // 副标题直接显示本机访问地址；取不到地址时退回功能说明
            subtitle: lan.localAddresses.isEmpty
                ? Text(loc.lanShareDesc)
                : SelectableText(
                    loc.lanLocalAddressWith(
                      lan.localAddresses
                          .map((address) => 'http://$address:${lan.sharePort}')
                          .join('\n'),
                    ),
                    style: const TextStyle(fontSize: 12, color: _hintColor),
                  ),
            activeThumbColor: const Color(0xFFe94560),
            value: settings.lanShareEnabled,
            onChanged: (value) {
              // 整体共享开关联动下方每个文件夹的共享开关
              settings.setAllLanFoldersShared(folderPaths, value);
              settings.setLanShareEnabled(value);
            },
          ),
          // 允许其他终端对本机共享视频执行的远程操作（默认关闭）
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(Icons.visibility_off_outlined),
            title: Text(loc.allowRemoteExcludeLabel),
            subtitle: Text(loc.allowRemoteExcludeDesc),
            activeThumbColor: const Color(0xFFe94560),
            value: settings.allowRemoteExclude,
            onChanged: settings.setAllowRemoteExclude,
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(Icons.file_copy_outlined),
            title: Text(loc.allowRemoteCopyLabel),
            subtitle: Text(loc.allowRemoteCopyDesc),
            activeThumbColor: const Color(0xFFe94560),
            value: settings.allowRemoteCopy,
            onChanged: settings.setAllowRemoteCopy,
          ),
          // 桌面端：关闭窗口时收起到托盘，便于其他终端继续访问本机视频
          if (Platform.isWindows)
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              secondary: const Icon(Icons.move_to_inbox),
              title: Text(loc.closeToTray),
              subtitle: Text(loc.closeToTrayDesc),
              activeThumbColor: const Color(0xFFe94560),
              value: settings.closeToTray,
              onChanged: settings.setCloseToTray,
            ),
          if (lan.error == LanError.serverStartFailed)
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline, color: Colors.redAccent),
              title: Text(
                loc.lanServerStartFailed,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
        ],
      ),
    );
  }

  /// 提示行：图标 + 同色小字，移动端两条提示共用
  Widget _hintRow(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: _hintColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, color: _hintColor),
          ),
        ),
      ],
    );
  }

  static String _lastSegment(String path) {
    var clean = path;
    while (clean.endsWith('/') || clean.endsWith('\\')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final index = clean.lastIndexOf(RegExp(r'[/\\]'));
    return index >= 0 ? clean.substring(index + 1) : clean;
  }
}
