import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:steam_flow/providers/settings_provider.dart' show PlayOrder;
import 'package:win32/win32.dart';

/// 读取 Windows 资源管理器窗口当前视图的排序方式。
///
/// 双击打开视频时，播放顺序应当与用户在资源管理器里看到的顺序一致。
/// 资源管理器真实的排序列（名称/修改日期/大小…）和方向保存在它自己的
/// 视图里，没有现成的 Win32 API 可查，只能通过 Shell 的 COM 接口读取：
///
/// `IShellWindows.FindWindowSW` → `IServiceProvider.QueryService`
/// → `IShellBrowser.QueryActiveShellView` → `IFolderView2.GetSortColumns`
///
/// 目标目录没有在资源管理器里打开、或读取失败时返回 `null`，
/// 由调用方回退到默认的按名称自然序。
class ExplorerSortService {
  /// 在后台 isolate 中读取（COM 需要独占一个 STA 线程初始化）。
  static Future<PlayOrder?> readPlayOrder(String folderPath) async {
    if (!Platform.isWindows) return null;
    try {
      return await compute(_readPlayOrderSync, folderPath);
    } catch (_) {
      return null;
    }
  }
}

/// 排序列使用的属性键都属于 FMTID_Storage（见 propkey.h）
const String _fmtidStorage = '{b725f130-47ef-101a-a5f1-02608c9eebac}';

/// 列名对应的属性键 PID（见 propkey.h）
const int _pidItemNameDisplay = 10;
const int _pidSize = 12;
const int _pidDateModified = 14;

/// 把资源管理器的排序列与方向映射成 App 内的播放顺序。
PlayOrder? _mapSortColumn(String fmtid, int pid, int direction) {
  // SORTCOLUMN.direction：正数升序、负数降序
  final ascending = direction >= 0;
  if (pid == _pidItemNameDisplay && fmtid == _fmtidStorage) {
    return ascending ? PlayOrder.sequential : PlayOrder.reverseSequential;
  }
  if (pid == _pidDateModified && fmtid == _fmtidStorage) {
    return ascending ? PlayOrder.oldestFirst : PlayOrder.newestFirst;
  }
  if (pid == _pidSize && fmtid == _fmtidStorage) {
    return ascending ? PlayOrder.sizeSmallest : PlayOrder.sizeLargest;
  }
  // 「类型」等其他列没有对应的播放顺序，返回 null 让调用方回退到按名称
  return null;
}

final class _Variant extends Struct {
  @Uint16()
  external int vt;
  @Uint16()
  external int wReserved1;
  @Uint16()
  external int wReserved2;
  @Uint16()
  external int wReserved3;
  external Pointer<Utf16> bstr;
  @Uint64()
  external int reserved;
}

/// 与 Windows SDK 的 SORTCOLUMN 结构一致：PROPERTYKEY + int direction
final class _SortColumn extends Struct {
  external GUID fmtid;
  @Uint32()
  external int pid;
  @Int32()
  external int direction;
}

/// 从接口指针取出 vtable 基址（接口指针指向的内存首字段即 vtable 指针）。
Pointer<IntPtr> _vtableOf(Pointer iface) => iface.cast<Pointer<IntPtr>>().value;

int _queryInterface(Pointer iface, String iid, Pointer<Pointer<IntPtr>> out) {
  final pIid = convertToIID(iid);
  try {
    final fn = (_vtableOf(iface) + 0)
        .cast<
          Pointer<
            NativeFunction<
              Int32 Function(Pointer, Pointer<GUID>, Pointer<Pointer<IntPtr>>)
            >
          >
        >()
        .value
        .asFunction<
          int Function(Pointer, Pointer<GUID>, Pointer<Pointer<IntPtr>>)
        >();
    return fn(iface, pIid, out);
  } finally {
    free(pIid);
  }
}

void _release(Pointer iface) {
  final fn = (_vtableOf(iface) + 2)
      .cast<Pointer<NativeFunction<Uint32 Function(Pointer)>>>()
      .value
      .asFunction<int Function(Pointer)>();
  fn(iface);
}

/// IServiceProvider::QueryService，vtable 索引 3
int _queryService(
  Pointer iface,
  String service,
  String iid,
  Pointer<Pointer<IntPtr>> out,
) {
  final pService = convertToIID(service);
  final pIid = convertToIID(iid);
  try {
    final fn = (_vtableOf(iface) + 3)
        .cast<
          Pointer<
            NativeFunction<
              Int32 Function(
                Pointer,
                Pointer<GUID>,
                Pointer<GUID>,
                Pointer<Pointer<IntPtr>>,
              )
            >
          >
        >()
        .value
        .asFunction<
          int Function(
            Pointer,
            Pointer<GUID>,
            Pointer<GUID>,
            Pointer<Pointer<IntPtr>>,
          )
        >();
    return fn(iface, pService, pIid, out);
  } finally {
    free(pService);
    free(pIid);
  }
}

/// IShellWindows::FindWindowSW，vtable 索引 15
int _findWindowSW(
  Pointer iface,
  Pointer<_Variant> loc,
  Pointer<_Variant> locRoot,
  Pointer<Int32> phwnd,
  Pointer<Pointer<IntPtr>> ppdisp,
) {
  final fn = (_vtableOf(iface) + 15)
      .cast<
        Pointer<
          NativeFunction<
            Int32 Function(
              Pointer,
              Pointer<_Variant>,
              Pointer<_Variant>,
              Int32,
              Pointer<Int32>,
              Int32,
              Pointer<Pointer<IntPtr>>,
            )
          >
        >
      >()
      .value
      .asFunction<
        int Function(
          Pointer,
          Pointer<_Variant>,
          Pointer<_Variant>,
          int,
          Pointer<Int32>,
          int,
          Pointer<Pointer<IntPtr>>,
        )
      >();
  // swClass = SWC_BROWSER(1)，swfwOptions = SWFO_NEEDDISPATCH(1)
  return fn(iface, loc, locRoot, 1, phwnd, 1, ppdisp);
}

/// IShellBrowser::QueryActiveShellView，vtable 索引 15
int _queryActiveShellView(Pointer iface, Pointer<Pointer<IntPtr>> out) {
  final fn = (_vtableOf(iface) + 15)
      .cast<
        Pointer<
          NativeFunction<Int32 Function(Pointer, Pointer<Pointer<IntPtr>>)>
        >
      >()
      .value
      .asFunction<int Function(Pointer, Pointer<Pointer<IntPtr>>)>();
  return fn(iface, out);
}

/// IFolderView2::GetSortColumnCount，vtable 索引 26
int _getSortColumnCount(Pointer iface, Pointer<Int32> count) {
  final fn = (_vtableOf(iface) + 26)
      .cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<Int32>)>>>()
      .value
      .asFunction<int Function(Pointer, Pointer<Int32>)>();
  return fn(iface, count);
}

/// IFolderView2::GetSortColumns，vtable 索引 28
int _getSortColumns(Pointer iface, Pointer<_SortColumn> columns, int count) {
  final fn = (_vtableOf(iface) + 28)
      .cast<
        Pointer<
          NativeFunction<Int32 Function(Pointer, Pointer<_SortColumn>, Int32)>
        >
      >()
      .value
      .asFunction<int Function(Pointer, Pointer<_SortColumn>, int)>();
  return fn(iface, columns, count);
}

/// 后台 isolate 入口：同步完成整条 COM 调用并返回播放顺序。
PlayOrder? _readPlayOrderSync(String folderPath) {
  final hrCo = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  // RPC_E_CHANGED_MODE 表示线程已被初始化（模式不同），仍可继续尝试
  const rpcEChangedMode = 0x80010106;
  if (FAILED(hrCo) && (hrCo & 0xFFFFFFFF) != rpcEChangedMode) return null;
  final needUninitialize = SUCCEEDED(hrCo);

  Pointer<COMObject>? shellWindows;
  BSTR? bstr;
  Pointer<_Variant>? loc;
  Pointer<_Variant>? locRoot;
  Pointer<Int32>? phwnd;
  Pointer<Pointer<IntPtr>>? ppdisp;
  Pointer<Pointer<IntPtr>>? provider;
  Pointer<Pointer<IntPtr>>? browser;
  Pointer<Pointer<IntPtr>>? view;
  Pointer<Pointer<IntPtr>>? folderView;
  Pointer<Int32>? count;
  Pointer<_SortColumn>? columns;

  try {
    shellWindows = COMObject.createFromID(
      '{9BA05972-F6A8-11CF-A442-00A0C90A8F39}',
      '{85CB6900-4D95-11CF-960C-0080C7F4EE85}',
    );

    bstr = BSTR.fromString(folderPath);
    loc = calloc<_Variant>();
    loc.ref.vt = VT_BSTR;
    loc.ref.bstr = bstr.ptr;
    // pvarLocRoot 不能传 nullptr：跨进程调用时该参数必须是非空 VARIANT
    locRoot = calloc<_Variant>()..ref.vt = VT_EMPTY;

    phwnd = calloc<Int32>();
    ppdisp = calloc<Pointer<IntPtr>>();
    final hrFind = _findWindowSW(
      shellWindows.ref.lpVtbl,
      loc,
      locRoot,
      phwnd,
      ppdisp,
    );
    if (FAILED(hrFind) || ppdisp.value == nullptr) return null;
    final pdisp = ppdisp.value;

    // IShellBrowser 不直接从 IDispatch 上 QI（跨进程未注册代理），
    // 需要经 IServiceProvider.QueryService 取
    provider = calloc<Pointer<IntPtr>>();
    final hrProvider = _queryInterface(
      pdisp,
      '{6D5140C1-7436-11CE-8034-00AA006009FA}',
      provider,
    );
    if (FAILED(hrProvider) || provider.value == nullptr) return null;

    browser = calloc<Pointer<IntPtr>>();
    final hrBrowser = _queryService(
      provider.value,
      '{000214E2-0000-0000-C000-000000000046}', // SID_SShellBrowser
      '{000214E2-0000-0000-C000-000000000046}', // IID_IShellBrowser
      browser,
    );
    if (FAILED(hrBrowser) || browser.value == nullptr) return null;

    view = calloc<Pointer<IntPtr>>();
    final hrView = _queryActiveShellView(browser.value, view);
    if (FAILED(hrView) || view.value == nullptr) return null;

    folderView = calloc<Pointer<IntPtr>>();
    final hrFolderView = _queryInterface(
      view.value,
      '{1af3a467-214f-4298-908e-06b03e0b39f9}', // IID_IFolderView2
      folderView,
    );
    if (FAILED(hrFolderView) || folderView.value == nullptr) return null;

    count = calloc<Int32>();
    final hrCount = _getSortColumnCount(folderView.value, count);
    if (FAILED(hrCount) || count.value <= 0) return null;

    columns = calloc<_SortColumn>(count.value);
    final hrColumns = _getSortColumns(folderView.value, columns, count.value);
    if (FAILED(hrColumns)) return null;

    // 取第一个能识别的列。分组视图下会多出分组列，忽略未知列即可。
    for (var i = 0; i < count.value; i++) {
      final column = (columns + i).ref;
      final order = _mapSortColumn(
        column.fmtid.toString(),
        column.pid,
        column.direction,
      );
      if (order != null) return order;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    if (columns != null) free(columns);
    if (count != null) free(count);
    if (folderView != null) {
      final iface = folderView.value;
      if (iface != nullptr) _release(iface);
      free(folderView);
    }
    if (view != null) {
      final iface = view.value;
      if (iface != nullptr) _release(iface);
      free(view);
    }
    if (browser != null) {
      final iface = browser.value;
      if (iface != nullptr) _release(iface);
      free(browser);
    }
    if (provider != null) {
      final iface = provider.value;
      if (iface != nullptr) _release(iface);
      free(provider);
    }
    if (ppdisp != null) {
      final iface = ppdisp.value;
      if (iface != nullptr) _release(iface);
      free(ppdisp);
    }
    if (phwnd != null) free(phwnd);
    if (locRoot != null) free(locRoot);
    if (loc != null) free(loc);
    bstr?.free();
    if (shellWindows != null) {
      _release(shellWindows.ref.lpVtbl);
      free(shellWindows);
    }
    if (needUninitialize) CoUninitialize();
  }
}
