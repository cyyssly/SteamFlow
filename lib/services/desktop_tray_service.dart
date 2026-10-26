import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/settings_provider.dart';

/// 桌面端窗口关闭行为。
///
/// 按设置决定点击右上角关闭按钮时直接退出，还是收起到系统托盘继续运行；
/// 收起后共享服务仍在后台，其他内网终端可以继续浏览本机视频。
/// 托盘图标提供「显示主界面」「退出」两个菜单项。
class DesktopTrayService with WindowListener, TrayListener {
  DesktopTrayService(this._settings);

  /// 全局实例：播放器关闭按钮复用同一份托盘状态
  static DesktopTrayService? instance;

  /// 托盘图标（随 flutter_assets 打包，tray_manager 会拼上资源目录）
  static const String _trayIcon = 'assets/icon/tray_icon.ico';

  final SettingsProvider _settings;

  bool _trayReady = false;
  bool _quitting = false;

  /// 只有 Windows 桌面端有托盘实现，其他平台直接跳过
  bool get _supported => Platform.isWindows;

  Future<void> initialize() async {
    if (!_supported) return;
    instance = this;
    await windowManager.ensureInitialized();
    // 拦截关闭按钮，交给 onWindowClose 决定是退出还是收起
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
  }

  @override
  void onWindowClose() async {
    await closeApplication();
  }

  /// 由标题栏关闭按钮或播放器关闭按钮调用。
  ///
  /// 按设置决定直接退出，还是收起到系统托盘继续运行。
  Future<void> closeApplication() async {
    if (!_supported || _quitting) return;
    if (!_settings.closeToTray) {
      await _exit();
      return;
    }
    await _hideToTray();
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _showWindow();
        break;
      case 'exit':
        await _exit();
        break;
    }
  }

  /// 收起到托盘。托盘创建失败时保持窗口可见，
  /// 否则窗口被隐藏、又没有托盘入口，应用会“消失”无法找回。
  Future<void> _hideToTray() async {
    if (!await _ensureTray()) return;
    await windowManager.hide();
  }

  Future<bool> _ensureTray() async {
    if (_trayReady) return true;
    try {
      await trayManager.setIcon(_trayIcon);
      await trayManager.setToolTip('SteamFlow');
      final loc = AppLocalizations.fromIndex(_settings.languageIndex);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: loc.trayShowWindow),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: loc.trayExit),
          ],
        ),
      );
      _trayReady = true;
      return true;
    } catch (error) {
      debugPrint('创建系统托盘失败：$error');
      return false;
    }
  }

  Future<void> _showWindow() async {
    await _destroyTray();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exit() async {
    _quitting = true;
    await _destroyTray();
    await windowManager.destroy();
  }

  Future<void> _destroyTray() async {
    if (!_trayReady) return;
    _trayReady = false;
    try {
      await trayManager.destroy();
    } catch (error) {
      debugPrint('销毁系统托盘失败：$error');
    }
  }
}
