import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:steam_flow/services/video_formats.dart';

/// Windows 右键菜单集成：在支持的视频格式上增加「用 SteamFlow 播放」。
///
/// 只写 HKCU（当前用户），不需要管理员权限，也不修改文件默认打开方式；
/// 开关关闭时递归删除对应注册表项，保持便携软件的可撤销性。
///
/// Windows 11 会把这类静态菜单项收进「显示更多选项」（传统右键菜单）。
class WindowsContextMenuService {
  WindowsContextMenuService._();

  static final WindowsContextMenuService instance =
      WindowsContextMenuService._();

  /// 菜单项标识（同时作为子键名与命令键名）
  static const String _verbKey = 'SteamFlow';

  /// 菜单显示文字的兜底值（调用方未传入本地化文字时使用）
  static const String _defaultMenuText = '用 SteamFlow 播放';

  /// 文件类型显示名与应用说明的兜底值
  static const String _defaultTypeName = 'SteamFlow 视频文件';
  static const String _defaultDescription = 'SteamFlow 视频播放器';

  /// 应用在 Windows 注册系统中的唯一 ProgID 名称
  static const String _progId = 'SteamFlow.Video.1';

  /// RegisteredApplications 下的注册名
  static const String _registeredAppName = 'SteamFlow';

  static const int _hkeyCurrentUser = 0x80000001;
  static const int _keyWrite = 0x20006;
  static const int _keyRead = 0x20019;
  static const int _regSz = 1;
  static const int _errorFileNotFound = 2;

  /// 当前用户的右键菜单项是否已经存在（任一支持格式即可）。
  ///
  /// 用于应用被移动目录或由其他构建注册过菜单时，启动后把命令路径
  /// 重写为本次启动的 exe，避免菜单指向已删除的旧副本。
  Future<bool> isInstalled() async {
    if (!Platform.isWindows) return false;
    for (final ext in supportedVideoExtensions) {
      if (_keyExists(
        'Software\\Classes\\SystemFileAssociations\\.$ext\\shell\\$_verbKey',
      )) {
        return true;
      }
    }
    return false;
  }

  /// 是否已注册为候选默认播放器（ProgID 存在即可）。
  ///
  /// 用于便携版移动目录后，启动时把命令路径刷新为当前 exe。
  Future<bool> hasDefaultAppRegistration() async {
    if (!Platform.isWindows) return false;
    return _keyExists('Software\\Classes\\$_progId');
  }

  /// 注册为视频文件的候选打开程序。
  ///
  /// 只把 SteamFlow 加入系统的候选列表（ProgID、OpenWithProgids、
  /// Applications、"默认应用"能力声明），**不会**替换用户当前的默认程序；
  /// 最终需要在系统「默认应用」页面由用户选择。
  ///
  /// [typeName] 为文件类型显示名，[description] 为「默认应用」里的应用说明，
  /// 均由调用方按当前界面语言传入（注册表只能存静态文本，语言变化后需重装）。
  Future<bool> installDefaultAppRegistration({
    String? typeName,
    String? description,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable;
      final exeName = exe.split(Platform.pathSeparator).last;
      final iconValue = '"$exe",0';
      final commandValue = '"$exe" "%1"';
      final localTypeName = typeName ?? _defaultTypeName;
      final localDescription = description ?? _defaultDescription;
      var ok = true;

      // ProgID：类型名、图标与打开命令
      final progBase = 'Software\\Classes\\$_progId';
      ok = _setValue(progBase, null, localTypeName) && ok;
      ok = _setValue(progBase, 'FriendlyTypeName', localTypeName) && ok;
      ok = _setValue(progBase, 'DefaultIcon', iconValue) && ok;
      ok =
          _setValue('$progBase\\shell\\open\\command', null, commandValue) &&
          ok;

      // "打开方式"候选 + "默认应用"能力声明
      const capabilities = 'Software\\$_registeredAppName\\Capabilities';
      for (final ext in supportedVideoExtensions) {
        // 个别扩展名的键可能被其他程序加了写权限限制（例如 .m4v），
        // 这类失败不影响其余格式，也不阻塞后续打开系统设置
        _setValue('Software\\Classes\\.$ext\\OpenWithProgids', _progId, '');
        ok =
            _setValue('$capabilities\\FileAssociations', '.$ext', _progId) &&
            ok;
      }

      // 以 exe 名登记的应用程序信息（供“打开方式”列表使用）
      final appBase = 'Software\\Classes\\Applications\\$exeName';
      ok = _setValue(appBase, 'FriendlyAppName', _registeredAppName) && ok;
      ok =
          _setValue('$appBase\\shell\\open\\command', null, commandValue) && ok;
      for (final ext in supportedVideoExtensions) {
        ok = _setValue('$appBase\\SupportedTypes', '.$ext', '') && ok;
      }

      // 在系统“默认应用”列表中展示本应用
      ok = _setValue(capabilities, 'ApplicationName', _registeredAppName) && ok;
      ok =
          _setValue(
            capabilities,
            'ApplicationDescription',
            localDescription,
          ) &&
          ok;
      ok = _setValue(capabilities, 'ApplicationIcon', iconValue) && ok;
      ok =
          _setValue(
            'Software\\RegisteredApplications',
            _registeredAppName,
            capabilities,
          ) &&
          ok;

      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「默认应用」页面，由用户选择 SteamFlow 作为默认播放器。
  ///
  /// Windows 11 支持按应用筛选；Windows 10 会忽略筛选参数并打开默认应用页。
  Future<bool> openDefaultAppsSettings() async {
    if (!Platform.isWindows) return false;
    if (_shellExecute(
      'ms-settings:defaultapps?registeredAppUser=$_registeredAppName',
    )) {
      return true;
    }
    return _shellExecute('ms-settings:defaultapps');
  }

  static bool _keyExists(String subKey) {
    final api = _Advapi32.instance;
    final subKeyPtr = subKey.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    try {
      final result = api.regOpenKeyExW(
        _hkeyCurrentUser,
        subKeyPtr,
        0,
        _keyRead,
        hKeyPtr,
      );
      if (result == 0) {
        api.regCloseKey(hKeyPtr.value);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      calloc.free(subKeyPtr);
      calloc.free(hKeyPtr);
    }
  }

  static bool _shellExecute(String target) {
    try {
      final api = _Shell32.instance;
      final operationPtr = 'open'.toNativeUtf16();
      final targetPtr = target.toNativeUtf16();
      try {
        // SW_SHOWNORMAL；返回值大于 32 表示成功
        final result = api.shellExecuteW(
          0,
          operationPtr,
          targetPtr,
          nullptr,
          nullptr,
          1,
        );
        return result > 32;
      } finally {
        calloc.free(operationPtr);
        calloc.free(targetPtr);
      }
    } catch (_) {
      return false;
    }
  }

  /// 为所有支持的视频扩展名注册右键菜单项。
  ///
  /// [menuText] 为菜单项显示文字（按当前界面语言传入）；注册表只能存静态
  /// 文本，因此界面语言变化时需要重新调用本方法覆盖标题。
  ///
  /// 返回 false 表示至少有一个扩展名写入失败（已写入的部分不回滚，
  /// 再次成功执行会覆盖为正确值）。
  Future<bool> install({String? menuText}) async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable;
      // 命令行里的占位符必须保留引号，路径含空格时才能正确传参
      final iconValue = '"$exe",0';
      final commandValue = '"$exe" "%1"';
      final text = menuText ?? _defaultMenuText;
      var ok = true;
      for (final ext in supportedVideoExtensions) {
        final base =
            'Software\\Classes\\SystemFileAssociations\\.$ext\\shell\\$_verbKey';
        // 先写命令键，再写菜单标题与图标
        ok = _setValue('$base\\command', null, commandValue) && ok;
        ok = _setValue(base, 'Icon', iconValue) && ok;
        ok = _setValue(base, null, text) && ok;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 删除为所有支持格式注册的右键菜单项。
  Future<bool> uninstall() async {
    if (!Platform.isWindows) return false;
    try {
      var ok = true;
      for (final ext in supportedVideoExtensions) {
        final base =
            'Software\\Classes\\SystemFileAssociations\\.$ext\\shell\\$_verbKey';
        ok = _deleteTree(base) && ok;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ── 注册表操作（advapi32）──

  static bool _setValue(String subKey, String? valueName, String value) {
    final api = _Advapi32.instance;
    final subKeyPtr = subKey.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    final dispositionPtr = calloc<Uint32>();
    try {
      final result = api.regCreateKeyExW(
        _hkeyCurrentUser,
        subKeyPtr,
        0,
        nullptr,
        0,
        _keyWrite,
        nullptr,
        hKeyPtr,
        dispositionPtr,
      );
      if (result != 0) return false;

      final hKey = hKeyPtr.value;
      final namePtr = valueName == null ? nullptr : valueName.toNativeUtf16();
      final valuePtr = value.toNativeUtf16();
      try {
        // 写入包含结尾 '\0' 的 UTF-16 字节数
        final byteLength = (value.length + 1) * 2;
        final setResult = api.regSetValueExW(
          hKey,
          namePtr,
          0,
          _regSz,
          valuePtr.cast<Uint8>(),
          byteLength,
        );
        return setResult == 0;
      } finally {
        if (namePtr != nullptr) calloc.free(namePtr);
        calloc.free(valuePtr);
        api.regCloseKey(hKey);
      }
    } finally {
      calloc.free(subKeyPtr);
      calloc.free(hKeyPtr);
      calloc.free(dispositionPtr);
    }
  }

  static bool _deleteTree(String subKey) {
    final api = _Advapi32.instance;
    final subKeyPtr = subKey.toNativeUtf16();
    try {
      final result = api.regDeleteTreeW(_hkeyCurrentUser, subKeyPtr);
      // 键不存在视为已删除成功，便于重复点击关闭
      return result == 0 || result == _errorFileNotFound;
    } finally {
      calloc.free(subKeyPtr);
    }
  }
}

/// advapi32 的按需加载封装（仅在 Windows 上使用）。
class _Advapi32 {
  _Advapi32._() {
    final library = DynamicLibrary.open('advapi32.dll');
    regCreateKeyExW = library
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Utf16>,
            Uint32,
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Pointer<IntPtr>,
            Pointer<Uint32>,
          ),
          int Function(
            int,
            Pointer<Utf16>,
            int,
            Pointer<Utf16>,
            int,
            int,
            Pointer<Void>,
            Pointer<IntPtr>,
            Pointer<Uint32>,
          )
        >('RegCreateKeyExW');
    regOpenKeyExW = library
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<IntPtr>,
          ),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)
        >('RegOpenKeyExW');
    regSetValueExW = library
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Uint8>,
            Uint32,
          ),
          int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
        >('RegSetValueExW');
    regDeleteTreeW = library
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>),
          int Function(int, Pointer<Utf16>)
        >('RegDeleteTreeW');
    regCloseKey = library
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'RegCloseKey',
        );
  }

  static final _Advapi32 instance = _Advapi32._();

  late final int Function(
    int,
    Pointer<Utf16>,
    int,
    Pointer<Utf16>,
    int,
    int,
    Pointer<Void>,
    Pointer<IntPtr>,
    Pointer<Uint32>,
  )
  regCreateKeyExW;
  late final int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)
  regOpenKeyExW;
  late final int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
  regSetValueExW;
  late final int Function(int, Pointer<Utf16>) regDeleteTreeW;
  late final int Function(int) regCloseKey;
}

/// shell32 的按需加载封装，用于打开系统设置页面。
class _Shell32 {
  _Shell32._() {
    final library = DynamicLibrary.open('shell32.dll');
    shellExecuteW = library
        .lookupFunction<
          IntPtr Function(
            IntPtr,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Int32,
          ),
          int Function(
            int,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            int,
          )
        >('ShellExecuteW');
  }

  static final _Shell32 instance = _Shell32._();

  late final int Function(
    int,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    int,
  )
  shellExecuteW;
}
