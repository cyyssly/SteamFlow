import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// 目录选择服务
///
/// 统一封装各平台的原生目录选择对话框，并做互斥保护。
///
/// 背景：Windows 上 `file_picker` 通过 FFI 直接在当前进程内调用 Shell 的
/// IFileOpenDialog（comdlg32.dll）。原生文件对话框**不允许并发打开**，
/// 重复调用会导致 Shell 侧访问冲突（0xC0000005），进程直接退出，且 Dart
/// 层无法捕获。因此在对话框显示期间拒绝新的选择请求，避免这类原生崩溃。
class DirectoryPickerService {
  DirectoryPickerService._();

  /// 是否已有原生目录选择对话框正在显示
  static bool _isPicking = false;

  /// 当前是否有目录选择对话框正在显示
  static bool get isPicking => _isPicking;

  /// 打开原生目录选择对话框。
  ///
  /// - 返回选中目录的路径；
  /// - 用户取消，或已有对话框正在显示（重复请求）时返回 null；
  /// - 原生对话框抛出异常时返回 null（不向上冒泡，避免中断调用方流程）。
  static Future<String?> pickDirectory({String? dialogTitle}) async {
    if (_isPicking) {
      debugPrint('[DirectoryPickerService] 已有目录选择对话框正在显示，忽略重复请求');
      return null;
    }
    _isPicking = true;
    try {
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
    } catch (e) {
      debugPrint('[DirectoryPickerService] 目录选择失败: $e');
      return null;
    } finally {
      _isPicking = false;
    }
  }

  /// 打开原生目录选择对话框，支持一次选择多个目录。
  ///
  /// Windows 使用 `IFileOpenDialog` 的多选模式；其他平台没有统一的多选
  /// 接口，退化为单选。
  ///
  /// - 返回选中目录的路径列表；
  /// - 用户取消、重复请求或发生异常时返回空列表。
  static Future<List<String>> pickDirectories({String? dialogTitle}) async {
    if (_isPicking) {
      debugPrint('[DirectoryPickerService] 已有目录选择对话框正在显示，忽略重复请求');
      return const [];
    }
    _isPicking = true;
    try {
      if (Platform.isWindows) {
        return await compute(_pickDirectoriesWindows, dialogTitle ?? '');
      }
      final single = await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
      return single == null ? const [] : [single];
    } catch (e) {
      debugPrint('[DirectoryPickerService] 目录选择失败: $e');
      return const [];
    } finally {
      _isPicking = false;
    }
  }

  // IFileOpenDialog 的选项位。win32 包里的同名枚举成员已标记为废弃，
  // 这里直接用数值，避免分析器报警告。
  static const int _fosNoChangeDir = 0x00000008;
  static const int _fosPickFolders = 0x00000020;
  static const int _fosForceFileSystem = 0x00000040;
  static const int _fosAllowMultiSelect = 0x00000200;
  static const int _fosPathMustExist = 0x00000800;

  /// 在独立 isolate 中弹出 Windows 原生目录对话框（多选）。
  ///
  /// 与 file_picker 的做法一致：对话框必须在使用它的线程上初始化 COM，
  /// 用完后在该线程上释放。放在独立 isolate 里可以避免影响主线程的 COM
  /// 状态（主线程上释放 COM 曾导致进程崩溃）。
  static List<String> _pickDirectoriesWindows(String dialogTitle) {
    final hrInit = CoInitializeEx(
      nullptr,
      COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
    );
    if (!SUCCEEDED(hrInit)) {
      debugPrint(
        '[DirectoryPickerService] CoInitializeEx 失败: 0x${hrInit.toRadixString(16)}',
      );
      return const [];
    }

    try {
      final dialog = FileOpenDialog.createInstance();
      try {
        final optionsPtr = calloc<Uint32>();
        final int options;
        try {
          final hr = dialog.getOptions(optionsPtr);
          if (!SUCCEEDED(hr)) return const [];
          options = optionsPtr.value;
        } finally {
          free(optionsPtr);
        }

        final hrSet = dialog.setOptions(
          options |
              _fosPickFolders |
              _fosAllowMultiSelect |
              _fosForceFileSystem |
              _fosPathMustExist |
              _fosNoChangeDir,
        );
        if (!SUCCEEDED(hrSet)) return const [];

        if (dialogTitle.isNotEmpty) {
          final title = dialogTitle.toNativeUtf16();
          try {
            dialog.setTitle(title);
          } finally {
            free(title);
          }
        }

        // 没有父窗口（0），与原 file_picker 默认行为一致。
        // 用户取消时返回 0x800704C7（ERROR_CANCELLED），按空结果处理。
        final hrShow = dialog.show(0);
        if (!SUCCEEDED(hrShow)) return const [];

        // win32 的 COM 包装类要求 ptr 指向「存放接口指针的那块内存」，
        // 而不是接口指针本身（参见 IUnknown.toInterface 的实现）。
        // 直接传 resultsHolder.value 会让后续方法调用读到错误的 vtable，
        // 进而跳到非法地址导致进程崩溃（0xC0000005）。
        final resultsHolder = calloc<COMObject>();
        final hrResults = dialog.getResults(
          resultsHolder.cast<Pointer<COMObject>>(),
        );
        if (!SUCCEEDED(hrResults)) {
          free(resultsHolder);
          return const [];
        }

        final items = IShellItemArray(resultsHolder);
        try {
          return _readItemPaths(items);
        } finally {
          _disposeCom(items);
        }
      } finally {
        _disposeCom(dialog);
      }
    } finally {
      CoUninitialize();
    }
  }

  /// 读取 [IShellItemArray] 中每一项的文件系统路径。
  static List<String> _readItemPaths(IShellItemArray items) {
    final paths = <String>[];
    final countPtr = calloc<Uint32>();
    try {
      final hrCount = items.getCount(countPtr);
      if (!SUCCEEDED(hrCount)) return paths;

      for (var i = 0; i < countPtr.value; i++) {
        final itemHolder = calloc<COMObject>();
        final hrItem = items.getItemAt(
          i,
          itemHolder.cast<Pointer<COMObject>>(),
        );
        if (!SUCCEEDED(hrItem)) {
          free(itemHolder);
          continue;
        }

        final item = IShellItem(itemHolder);
        try {
          final pathPtr = calloc<Pointer<Utf16>>();
          try {
            final hrName = item.getDisplayName(SIGDN_FILESYSPATH, pathPtr);
            if (SUCCEEDED(hrName) && pathPtr.value != nullptr) {
              paths.add(pathPtr.value.toDartString());
              // 路径字符串由 Shell 用 CoTaskMemAlloc 分配，需用对应函数释放
              CoTaskMemFree(pathPtr.value);
            }
          } finally {
            free(pathPtr);
          }
        } finally {
          _disposeCom(item);
        }
      }
    } finally {
      free(countPtr);
    }
    return paths;
  }

  /// 释放一个 COM 包装对象：解除 finalizer、减少引用计数并回收存放接口指针的内存。
  ///
  /// 与 win32 内部 finalizer 的行为保持一致，但改成确定性地立即执行，
  /// 避免依赖 GC 时机（isolate 退出后 GC 未必会执行）。
  static void _disposeCom(IUnknown object) {
    object.detach();
    object.release();
    free(object.ptr);
  }
}
