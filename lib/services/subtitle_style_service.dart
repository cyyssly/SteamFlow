import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

typedef _MpvSetPropertyStringNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> value);
typedef _MpvSetPropertyStringDart =
    int Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> value);

/// 通过 libmpv 的 C API 直接设置字幕字体与字号。
///
/// media_kit 没有把字幕样式暴露成 Dart 方法，但它的播放器内核就是 libmpv，
/// 因此这里用 FFI 取 `mpv_set_property_string`，对播放器句柄写入
/// `sub-font` / `sub-font-size` 等属性，修改会实时反映到画面上。
///
/// 字体的解析由 libmpv 自己负责（Windows 走 DirectWrite、Android 走
/// fontconfig），传入系统已安装的字体名即可；`sans-serif` 为系统默认。
class SubtitleStyleService {
  SubtitleStyleService._();

  static final SubtitleStyleService instance = SubtitleStyleService._();

  _MpvSetPropertyStringDart? _setPropertyString;
  bool _resolved = false;

  /// 查找并缓存 `mpv_set_property_string`。
  ///
  /// 取不到时返回 null 并静默降级（例如平台不受支持或动态库缺失），
  /// 不影响播放器本身的其它功能。
  _MpvSetPropertyStringDart? _resolve() {
    if (_resolved) return _setPropertyString;
    _resolved = true;

    for (final name in _libraryNames()) {
      try {
        final lib = DynamicLibrary.open(name);
        _setPropertyString = lib
            .lookupFunction<
              _MpvSetPropertyStringNative,
              _MpvSetPropertyStringDart
            >('mpv_set_property_string');
        return _setPropertyString;
      } catch (_) {
        // 名称不在搜索路径时继续尝试下一个；全部失败则放弃
      }
    }
    return null;
  }

  /// 各平台 libmpv 动态库的常见名称（与 media_kit 的加载顺序一致）。
  List<String> _libraryNames() {
    if (Platform.isWindows) {
      return const ['libmpv-2.dll', 'mpv-2.dll', 'mpv-1.dll'];
    }
    if (Platform.isAndroid) {
      return const ['libmpv.so', 'libmpv.so.2', 'libmpv.so.1'];
    }
    return const [];
  }

  /// 把字体与字号写入指定播放器的 libmpv 实例。
  ///
  /// 可重复调用：设置页改动与播放页的快捷加减都走这里。
  Future<void> applyToPlayer(
    Player player, {
    required String fontFamily,
    required int fontSize,
  }) async {
    final setProperty = _resolve();
    if (setProperty == null) return;

    final int address;
    try {
      // 等待播放内核初始化完成后再取句柄
      address = await player.handle;
    } catch (_) {
      return;
    }
    if (address == 0) return;

    final ctx = Pointer<Void>.fromAddress(address);
    _set(ctx, setProperty, 'sub-font', fontFamily);
    _set(ctx, setProperty, 'sub-font-size', '$fontSize');
    // ASS/SSA 字幕默认沿用文件内嵌样式，force 才会应用上面的字体与字号
    _set(ctx, setProperty, 'sub-ass-override', 'force');
  }

  void _set(
    Pointer<Void> ctx,
    _MpvSetPropertyStringDart setProperty,
    String name,
    String value,
  ) {
    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      setProperty(ctx, namePtr, valuePtr);
    } finally {
      calloc.free(namePtr);
      calloc.free(valuePtr);
    }
  }
}
