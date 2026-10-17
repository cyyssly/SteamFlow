import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Windows「真·独占全屏」控制器。
///
/// 播放页与瀑布流浏览页共用同一个实例：全局只保存一份原始窗口样式与位置，
/// 避免两个页面各自进出全屏时互相覆盖，导致退出全屏后窗口边框与尺寸错乱。
class FullscreenService {
  FullscreenService._();

  static final FullscreenService instance = FullscreenService._();

  bool _isFullscreen = false;

  /// 当前是否处于全屏
  bool get isFullscreen => _isFullscreen;

  // 原始窗口样式与位置（仅在首次进入全屏时记录）
  int? _originalStyle;
  int? _originalX;
  int? _originalY;
  int? _originalWidth;
  int? _originalHeight;

  /// 进入全屏。
  ///
  /// 已处于全屏时直接返回，防止把「全屏之后的窗口样式」误记为原始样式。
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
  /// 未处于全屏时直接返回，避免在窗口已恢复的情况下重复设置窗口位置。
  void exit() {
    if (!_isFullscreen) return;
    if (Platform.isWindows) {
      _restoreWindowsWindow();
    }
    _isFullscreen = false;
  }

  /// 取前台窗口句柄；取不到时按窗口标题查找，仍取不到则返回 0
  int _foregroundWindow(DynamicLibrary user32) {
    final getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetForegroundWindow',
        );
    var hwnd = getForegroundWindow();

    // 如果获取不到前台窗口，尝试通过窗口标题查找
    if (hwnd == 0) {
      final findWindowW = user32
          .lookupFunction<
            IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
            int Function(Pointer<Utf16>, Pointer<Utf16>)
          >('FindWindowW');
      hwnd = findWindowW(nullptr, 'SteamFlow'.toNativeUtf16());
    }
    return hwnd;
  }

  /// 去掉窗口边框与标题栏并铺满屏幕；取不到窗口句柄时返回 false
  bool _enterWindowsFullscreen() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _foregroundWindow(user32);
      if (hwnd == 0) return false;

      // 先激活窗口，确保获取的是正确的窗口句柄
      final setForegroundWindow = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'SetForegroundWindow',
          );
      setForegroundWindow(hwnd);

      // 获取屏幕分辨率
      final getSystemMetrics = user32
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'GetSystemMetrics',
          );
      final screenWidth = getSystemMetrics(0); // SM_CXSCREEN
      final screenHeight = getSystemMetrics(1); // SM_CYSCREEN

      // 保存原始窗口样式
      final getWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32),
            int Function(int, int)
          >('GetWindowLongPtrW');
      _originalStyle = getWindowLongPtr(hwnd, -16); // GWL_STYLE

      // 保存原始窗口位置和大小（使用 calloc 分配内存）
      final getWindowRect = user32
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<Int32>),
            int Function(int, Pointer<Int32>)
          >('GetWindowRect');
      final rect = calloc<Int32>(4);
      getWindowRect(hwnd, rect);
      _originalX = rect[0];
      _originalY = rect[1];
      _originalWidth = rect[2] - rect[0];
      _originalHeight = rect[3] - rect[1];
      calloc.free(rect);

      // 移除窗口边框和标题栏
      final setWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32, IntPtr),
            int Function(int, int, int)
          >('SetWindowLongPtrW');
      const wsOverlappedwindow = 0x00CF0000;
      const wsPopup = 0x80000000;
      setWindowLongPtr(
        hwnd,
        -16,
        _originalStyle! & ~wsOverlappedwindow | wsPopup,
      );

      // 设置窗口覆盖整个屏幕
      final setWindowPos = user32
          .lookupFunction<
            Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
            int Function(int, int, int, int, int, int, int)
          >('SetWindowPos');
      // 使用 HWND_TOPMOST 确保窗口在最顶层
      setWindowPos(hwnd, -1, 0, 0, screenWidth, screenHeight, 0);
      return true;
    } catch (_) {
      // 忽略错误
      return false;
    }
  }

  /// 恢复原始窗口样式与位置
  void _restoreWindowsWindow() {
    if (_originalStyle == null) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _foregroundWindow(user32);
      if (hwnd == 0) return;

      // 恢复原始窗口样式
      final setWindowLongPtr = user32
          .lookupFunction<
            IntPtr Function(IntPtr, Int32, IntPtr),
            int Function(int, int, int)
          >('SetWindowLongPtrW');
      setWindowLongPtr(hwnd, -16, _originalStyle!);

      // 恢复窗口到原始位置和大小，同时取消最顶层状态
      final setWindowPos = user32
          .lookupFunction<
            Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
            int Function(int, int, int, int, int, int, int)
          >('SetWindowPos');
      const hwndNotopmost = -2;

      if (_originalX != null &&
          _originalY != null &&
          _originalWidth != null &&
          _originalHeight != null) {
        setWindowPos(
          hwnd,
          hwndNotopmost,
          _originalX!,
          _originalY!,
          _originalWidth!,
          _originalHeight!,
          0, // 移除 SWP_NOACTIVATE，允许窗口自动激活
        );
      } else {
        // 如果没有保存原始位置，使用默认恢复
        setWindowPos(hwnd, hwndNotopmost, 0, 0, 800, 600, 0);
      }

      // 在窗口样式和位置恢复后，再次显式激活窗口确保获取焦点
      final setForegroundWindow = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'SetForegroundWindow',
          );
      setForegroundWindow(hwnd);
    } catch (_) {
      // 忽略错误
    }
  }
}
