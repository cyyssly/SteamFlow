import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Windows「真·独占全屏」控制器。
///
/// 播放页与瀑布流浏览页共用同一个实例：全局只保存一份原始窗口样式与位置，
/// 避免两个页面各自进出全屏时互相覆盖，导致退出全屏后窗口边框与尺寸错乱。
///
/// 实现上有两点必须小心：
/// 1. 窗口句柄只在首次成功定位后缓存复用，不能每次都靠 GetForegroundWindow
///    现取 —— 全屏期间前台窗口可能变成任务栏等其它窗口，一旦取错就会把窗口
///    样式与位置设到别人身上，自己反而退不出全屏。
/// 2. 原始样式与位置只在窗口确实处于普通样式时记录，绝不记录「已经全屏之后」
///    的尺寸 —— 否则每次退出全屏都会恢复到全屏尺寸，表现为再也退不出全屏。
class FullscreenService {
  FullscreenService._();

  static final FullscreenService instance = FullscreenService._();

  bool _isFullscreen = false;

  /// 当前是否处于全屏
  bool get isFullscreen => _isFullscreen;

  /// 缓存的本应用主窗口句柄（0 表示尚未定位）
  int _hwnd = 0;

  // 原始窗口样式与位置（在窗口处于普通样式时记录）
  int? _originalStyle;
  int? _originalX;
  int? _originalY;
  int? _originalWidth;
  int? _originalHeight;

  /// 进入全屏。
  ///
  /// 已处于全屏时直接返回；窗口设置失败时不修改状态，防止状态与窗口实际
  /// 情况不一致——那会让下次进入全屏把全屏尺寸记成原始尺寸。
  void enter() {
    if (_isFullscreen) return;
    if (!Platform.isWindows) {
      _isFullscreen = true;
      return;
    }
    if (_enterWindowsFullscreen()) {
      _isFullscreen = true;
    }
  }

  /// 退出全屏并恢复原始窗口。
  ///
  /// 未处于全屏时直接返回；恢复失败时保留全屏标记，理由同上。
  void exit() {
    if (!_isFullscreen) return;
    if (Platform.isWindows && !_restoreWindowsWindow()) return;
    _isFullscreen = false;
  }

  /// 定位本应用主窗口；成功定位后缓存句柄复用。
  ///
  /// 顺序：缓存（用 IsWindow 校验仍然有效）→ 按窗口标题查找
  /// （windows/runner/main.cpp 里标题固定为 SteamFlow）→ 前台窗口兜底。
  int _resolveWindow(DynamicLibrary user32) {
    final isWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
    if (_hwnd != 0 && isWindow(_hwnd) != 0) return _hwnd;

    final findWindowW = user32
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    final title = 'SteamFlow'.toNativeUtf16();
    try {
      _hwnd = findWindowW(nullptr, title);
    } finally {
      malloc.free(title);
    }

    if (_hwnd == 0) {
      final getForegroundWindow = user32
          .lookupFunction<IntPtr Function(), int Function()>(
            'GetForegroundWindow',
          );
      _hwnd = getForegroundWindow();
    }
    return _hwnd;
  }

  /// 去掉窗口边框与标题栏并铺满屏幕；取不到窗口句柄时返回 false
  bool _enterWindowsFullscreen() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _resolveWindow(user32);
      if (hwnd == 0) return false;

      const wsOverlappedWindow = 0x00CF0000;
      const wsPopup = 0x80000000;

      final getWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32),
            int Function(int, int)
          >('GetWindowLongPtrW');
      final currentStyle = getWindowLongPtr(hwnd, _gwlStyle);

      // 仅在窗口当前处于普通样式时记录原始样式与位置。
      // 已经去掉边框（WS_POPUP）之后的尺寸绝不能当作原始尺寸，
      // 否则退出全屏会恢复到全屏尺寸，看起来就像全屏切换失效。
      if (currentStyle & wsPopup == 0) {
        _originalStyle = currentStyle;

        final getWindowRect = user32
            .lookupFunction<
              Int32 Function(IntPtr, Pointer<Int32>),
              int Function(int, Pointer<Int32>)
            >('GetWindowRect');
        final rect = calloc<Int32>(4);
        try {
          getWindowRect(hwnd, rect);
          _originalX = rect[0];
          _originalY = rect[1];
          _originalWidth = rect[2] - rect[0];
          _originalHeight = rect[3] - rect[1];
        } finally {
          calloc.free(rect);
        }
      }

      // 获取屏幕分辨率
      final getSystemMetrics = user32
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'GetSystemMetrics',
          );
      final screenWidth = getSystemMetrics(0); // SM_CXSCREEN
      final screenHeight = getSystemMetrics(1); // SM_CYSCREEN

      // 移除窗口边框和标题栏
      final setWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32, IntPtr),
            int Function(int, int, int)
          >('SetWindowLongPtrW');
      setWindowLongPtr(
        hwnd,
        _gwlStyle,
        currentStyle & ~wsOverlappedWindow | wsPopup,
      );

      // 铺满整屏。
      // SWP_FRAMECHANGED：样式改完后让 Windows 重算窗口边框，否则框架不会立即
      // 刷新，会出现闪烁与残留画面。
      // SWP_NOACTIVATE：不抢前台。原实现既调 SetForegroundWindow、又用 flags=0
      // 强行激活，会触发系统「防止焦点窃取」，任务栏按钮因此反复闪烁。
      final setWindowPos = user32
          .lookupFunction<
            Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
            int Function(int, int, int, int, int, int, int)
          >('SetWindowPos');
      setWindowPos(
        hwnd,
        _hwndTopmost,
        0,
        0,
        screenWidth,
        screenHeight,
        _swpFrameChanged | _swpNoActivate,
      );
      return true;
    } catch (_) {
      // 忽略错误
      return false;
    }
  }

  /// 恢复原始窗口样式与位置；未记录过原始值或取不到窗口句柄时返回 false
  bool _restoreWindowsWindow() {
    final originalStyle = _originalStyle;
    if (originalStyle == null) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _resolveWindow(user32);
      if (hwnd == 0) return false;

      // 恢复原始窗口样式
      final setWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32, IntPtr),
            int Function(int, int, int)
          >('SetWindowLongPtrW');
      setWindowLongPtr(hwnd, _gwlStyle, originalStyle);

      // 恢复原始位置与尺寸并取消最顶层；同样不做前台抢占，
      // 窗口在样式与尺寸变更期间会保持原有激活状态。
      final setWindowPos = user32
          .lookupFunction<
            Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
            int Function(int, int, int, int, int, int, int)
          >('SetWindowPos');
      setWindowPos(
        hwnd,
        _hwndNotTopmost,
        _originalX ?? 0,
        _originalY ?? 0,
        _originalWidth ?? 800,
        _originalHeight ?? 600,
        _swpFrameChanged | _swpNoActivate,
      );
      return true;
    } catch (_) {
      // 忽略错误
      return false;
    }
  }
}

/// GWL_STYLE
const int _gwlStyle = -16;

/// SetWindowPos 的 hWndInsertAfter
const int _hwndTopmost = -1;
const int _hwndNotTopmost = -2;

/// SetWindowPos 标志位
const int _swpNoActivate = 0x0010;
const int _swpFrameChanged = 0x0020;
