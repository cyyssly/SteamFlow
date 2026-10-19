import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

/// 视频首帧缩略图。
///
/// [bytes] 为 PNG 编码后的字节，[width] / [height] 是**缩略图位图**的尺寸
/// （不含任何裁剪或留黑边），可直接用于推导宽高比。
///
/// [sourceWidth] / [sourceHeight] 是视频的**真实分辨率**：缩略图会被等比
/// 缩放到 512 以内，只能反映宽高比，不能反映真实像素，因此单独通过 Shell
/// 属性读取；不可用时为 null。
class VideoThumbnail {
  final Uint8List bytes;
  final int width;
  final int height;
  final int? sourceWidth;
  final int? sourceHeight;

  const VideoThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
    this.sourceWidth,
    this.sourceHeight,
  });

  double get aspectRatio => height > 0 ? width / height : 1;
}

// ── Windows 实现：通过 Shell 缩略图接口取视频首帧 ──
//
// 相比自行解码，这条路径有两点好处：
// 1. 复用 Windows 自己的缩略图（缓存与解码器），二次访问几乎零成本；
// 2. 返回的位图保持原始宽高比，可直接用于瀑布流布局。
//
// 该文件不依赖 Flutter，因此可以用 `dart run` 单独验证。

/// 请求的缩略图最大边长。
const int _maxSize = 512;

/// `SIIGBF_THUMBNAILONLY`：只要真实缩略图，没有时直接失败（避免拿到通用图标）。
const int _siigbfThumbnailOnly = 0x08;

/// `COINIT_APARTMENTTHREADED`
const int _coinitApartmentThreaded = 0x02;

/// IShellItemImageFactory 的 IID：{bcc18b79-ba16-442f-80c4-8a59c30c463b}
const int _iidData1 = 0xbcc18b79;
const int _iidData2 = 0xba16;
const int _iidData3 = 0x442f;
const List<int> _iidData4 = [0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b];

/// IPropertyStore 的 IID：{886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}
const int _iidPropStore1 = 0x886d8eeb;
const int _iidPropStore2 = 0x8cf2;
const int _iidPropStore3 = 0x4446;
const List<int> _iidPropStore4 = [
  0x8d,
  0x02,
  0xcd,
  0xba,
  0x1d,
  0xbd,
  0xcf,
  0x99,
];

/// 视频属性集的 fmtid：{64440491-4c8b-11d1-8b70-080036b11a03}
/// （小端字节序，直接写入 [_PropertyKey.fmtid]）
///
/// 即资源管理器「帧宽度 / 帧高度」两列所用的属性集，实测可拿到真实像素。
const List<int> _pkeyVideoFmtid = [
  0x91,
  0x04,
  0x44,
  0x64,
  0x8b,
  0x4c,
  0xd1,
  0x11,
  0x8b,
  0x70,
  0x08,
  0x00,
  0x36,
  0xb1,
  0x1a,
  0x03,
];

/// 帧宽度 / 帧高度在该属性集中的 pid
const int _pkeyVideoFrameWidthPid = 3;
const int _pkeyVideoFrameHeightPid = 4;

/// PROPVARIANT 的 `VT_UI4`
const int _vtUi4 = 19;

/// 生成单个视频的缩略图；失败（无缩略图/文件不存在）返回 null。
VideoThumbnail? windowsVideoThumbnailSync(String path) {
  if (!File(path).existsSync()) return null;
  try {
    return _extract(path);
  } catch (_) {
    return null;
  }
}

/// 批量生成缩略图，供后台 isolate 一次调用。
List<VideoThumbnail?> windowsVideoThumbnailsSync(List<String> paths) => [
  for (final path in paths) windowsVideoThumbnailSync(path),
];

VideoThumbnail? _extract(String path) {
  final shell32 = DynamicLibrary.open('shell32.dll');
  final ole32 = DynamicLibrary.open('ole32.dll');
  final gdi32 = DynamicLibrary.open('gdi32.dll');
  final user32 = DynamicLibrary.open('user32.dll');

  final coInitializeEx = ole32
      .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
        'CoInitializeEx',
      );
  final coUninitialize = ole32
      .lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
        'CoUninitialize',
      );
  final shCreateItemFromParsingName = shell32
      .lookupFunction<_ShCreateItemNative, _ShCreateItemDart>(
        'SHCreateItemFromParsingName',
      );
  final getObject = gdi32.lookupFunction<_GetObjectNative, _GetObjectDart>(
    'GetObjectW',
  );
  final getDIBits = gdi32.lookupFunction<_GetDIBitsNative, _GetDIBitsDart>(
    'GetDIBits',
  );
  final deleteObject = gdi32
      .lookupFunction<_DeleteObjectNative, _DeleteObjectDart>('DeleteObject');
  final getDC = user32.lookupFunction<_GetDCNative, _GetDCDart>('GetDC');
  final releaseDC = user32.lookupFunction<_ReleaseDCNative, _ReleaseDCDart>(
    'ReleaseDC',
  );

  // COM 必须先在本线程初始化。返回 S_FALSE 说明本线程早已初始化过，
  // 此时不能再配对调用 CoUninitialize，否则会把别人的引用计数减掉。
  final initResult = coInitializeEx(nullptr, _coinitApartmentThreaded);
  final ownsCom = initResult == 0; // S_OK

  final pathPtr = path.toNativeUtf16();
  final iidPtr = calloc<_Guid>();
  final itemPtr = calloc<Pointer<Void>>();
  final sizePtr = calloc<_Size>();
  final bitmapHandlePtr = calloc<Pointer<Void>>();
  final bitmapPtr = calloc<_Bitmap>();
  final bitmapInfoPtr = calloc<_BitmapInfo>();

  Pointer<Uint8>? pixelsPtr;
  Pointer<Void> item = nullptr;
  Pointer<Void> bitmap = nullptr;
  Pointer<Void> hdc = nullptr;

  try {
    iidPtr.ref.data1 = _iidData1;
    iidPtr.ref.data2 = _iidData2;
    iidPtr.ref.data3 = _iidData3;
    for (var i = 0; i < _iidData4.length; i++) {
      iidPtr.ref.data4[i] = _iidData4[i];
    }

    if (shCreateItemFromParsingName(pathPtr, nullptr, iidPtr, itemPtr) != 0) {
      return null;
    }
    item = itemPtr.value;
    if (item == nullptr) return null;

    sizePtr.ref.cx = _maxSize;
    sizePtr.ref.cy = _maxSize;
    final getImage = _comSlot<_GetImageNative>(
      item,
      3,
    ).asFunction<_GetImageDart>();
    // SIZE 在 x64 上按 8 字节整数走寄存器，这里手工打包成 Int64，
    // 避开 Dart FFI 传结构体按值的 ABI 差异。
    final size = sizePtr.ref.cx | (sizePtr.ref.cy << 32);
    if (getImage(item, size, _siigbfThumbnailOnly, bitmapHandlePtr) != 0) {
      return null;
    }
    bitmap = bitmapHandlePtr.value;
    if (bitmap == nullptr) return null;

    if (getObject(bitmap, sizeOf<_Bitmap>(), bitmapPtr) == 0) return null;
    final width = bitmapPtr.ref.bmWidth;
    final height = bitmapPtr.ref.bmHeight;
    if (width <= 0 || height <= 0) return null;

    final byteLength = width * height * 4;
    pixelsPtr = calloc<Uint8>(byteLength);

    final header = bitmapInfoPtr.ref;
    header.biSize = 40; // sizeof(BITMAPINFOHEADER)
    header.biWidth = width;
    header.biHeight = -height; // 负值表示自顶向下的像素顺序
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = 0; // BI_RGB

    hdc = getDC(nullptr);
    if (hdc == nullptr) return null;
    if (getDIBits(hdc, bitmap, 0, height, pixelsPtr, bitmapInfoPtr, 0) == 0) {
      return null;
    }

    // 拷贝一份再交给 image 包：calloc 的内存随后会被释放。
    // 32 位 BI_RGB 的 DIB 不含 Alpha 信息，第 4 个字节是「未使用」的，
    // GDI 通常填 0；若原样当作 Alpha 使用，整个画面会全透明。
    // 统一改写为不透明，同时也消除该字节随机值带来的编码体积抖动。
    final bgra = Uint8List.fromList(pixelsPtr.asTypedList(byteLength));
    for (var i = 3; i < bgra.length; i += 4) {
      bgra[i] = 255;
    }
    final frame = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgra.buffer,
      order: img.ChannelOrder.bgra,
    );
    final frameSize = _queryFrameSize(path);
    return VideoThumbnail(
      bytes: Uint8List.fromList(img.encodePng(frame)),
      width: width,
      height: height,
      sourceWidth: frameSize?.width,
      sourceHeight: frameSize?.height,
    );
  } finally {
    if (hdc != nullptr) releaseDC(nullptr, hdc);
    if (bitmap != nullptr) deleteObject(bitmap);
    if (item != nullptr) {
      _comSlot<_ReleaseNative>(item, 2).asFunction<_ReleaseDart>()(item);
    }
    if (pixelsPtr != null) calloc.free(pixelsPtr);
    calloc.free(bitmapInfoPtr);
    calloc.free(bitmapPtr);
    calloc.free(bitmapHandlePtr);
    calloc.free(sizePtr);
    calloc.free(itemPtr);
    calloc.free(iidPtr);
    malloc.free(pathPtr);
    if (ownsCom) coUninitialize();
  }
}

/// 读取视频的真实分辨率（宽 × 高）；Shell 属性不可用时返回 null。
///
/// 走 Shell 属性存储中的「帧宽度 / 帧高度」属性（资源管理器同名两列的数据源），
/// 它们是视频的**原始像素尺寸**，不受缩略图缩放影响。
/// 部分容器/未索引的文件可能取不到，此时返回 null，由调用方显示「未知」。
({int width, int height})? _queryFrameSize(String path) {
  final shell32 = DynamicLibrary.open('shell32.dll');
  final ole32 = DynamicLibrary.open('ole32.dll');

  final coInitializeEx = ole32
      .lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
        'CoInitializeEx',
      );
  final coUninitialize = ole32
      .lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
        'CoUninitialize',
      );
  final getPropertyStore = shell32
      .lookupFunction<_ShGetPropertyStoreNative, _ShGetPropertyStoreDart>(
        'SHGetPropertyStoreFromParsingName',
      );

  final initResult = coInitializeEx(nullptr, _coinitApartmentThreaded);
  final ownsCom = initResult == 0; // S_OK

  final pathPtr = path.toNativeUtf16();
  final iidPtr = calloc<_Guid>();
  final storePtr = calloc<Pointer<Void>>();
  final keyPtr = calloc<_PropertyKey>();
  final variantPtr = calloc<_PropVariant>();

  Pointer<Void> store = nullptr;
  try {
    iidPtr.ref.data1 = _iidPropStore1;
    iidPtr.ref.data2 = _iidPropStore2;
    iidPtr.ref.data3 = _iidPropStore3;
    for (var i = 0; i < _iidPropStore4.length; i++) {
      iidPtr.ref.data4[i] = _iidPropStore4[i];
    }
    // GPS_DEFAULT = 0
    if (getPropertyStore(pathPtr, nullptr, 0, iidPtr, storePtr) != 0) {
      return null;
    }
    store = storePtr.value;
    if (store == nullptr) return null;

    // System.Video.FrameWidth / FrameHeight 共用同一个 fmtid，仅 pid 不同
    for (var i = 0; i < _pkeyVideoFmtid.length; i++) {
      keyPtr.ref.fmtid[i] = _pkeyVideoFmtid[i];
    }

    final getValue = _comSlot<_GetValueNative>(
      store,
      5,
    ).asFunction<_GetValueDart>();

    keyPtr.ref.pid = _pkeyVideoFrameWidthPid;
    if (getValue(store, keyPtr, variantPtr) != 0 ||
        variantPtr.ref.vt != _vtUi4) {
      return null;
    }
    final width = variantPtr.ref.uintValue;

    // 复用同一个 PROPVARIANT，读第二个属性前先清空
    variantPtr.ref
      ..vt = 0
      ..reserved1 = 0
      ..reserved2 = 0
      ..reserved3 = 0
      ..uintValue = 0
      ..padding = 0;

    keyPtr.ref.pid = _pkeyVideoFrameHeightPid;
    if (getValue(store, keyPtr, variantPtr) != 0 ||
        variantPtr.ref.vt != _vtUi4) {
      return null;
    }
    final height = variantPtr.ref.uintValue;

    if (width <= 0 || height <= 0) return null;
    return (width: width, height: height);
  } finally {
    if (store != nullptr) {
      _comSlot<_ReleaseNative>(store, 2).asFunction<_ReleaseDart>()(store);
    }
    calloc.free(variantPtr);
    calloc.free(keyPtr);
    calloc.free(storePtr);
    calloc.free(iidPtr);
    malloc.free(pathPtr);
    if (ownsCom) coUninitialize();
  }
}

/// 取 COM 对象虚表第 [index] 个槽位指向的函数。
///
/// COM 对象内存的首个指针即虚表地址，虚表本身是一个「函数指针数组」；
/// IUnknown 占 0~2 号槽（QueryInterface / AddRef / Release），
/// 其余方法从 3 号开始。
///
/// 注意这里有**两次解引用**：先读出虚表地址，再从该地址读出第 index
/// 个槽位里的函数指针。少读一次就会跳到「槽位自身的内存地址」上。
Pointer<NativeFunction<T>> _comSlot<T extends Function>(
  Pointer<Void> comObject,
  int index,
) {
  final vtableAddress = comObject.cast<IntPtr>().value;
  final slots = Pointer<IntPtr>.fromAddress(vtableAddress);
  return Pointer<NativeFunction<T>>.fromAddress(slots[index]);
}

typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeExDart = int Function(Pointer<Void>, int);

typedef _CoUninitializeNative = Void Function();
typedef _CoUninitializeDart = void Function();

typedef _ShCreateItemNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Void>,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );
typedef _ShCreateItemDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Void>,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );

typedef _ReleaseNative = Uint32 Function(Pointer<Void>);
typedef _ReleaseDart = int Function(Pointer<Void>);

typedef _GetImageNative =
    Int32 Function(Pointer<Void>, Int64, Int32, Pointer<Pointer<Void>>);
typedef _GetImageDart =
    int Function(Pointer<Void>, int, int, Pointer<Pointer<Void>>);

typedef _GetObjectNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<_Bitmap>);
typedef _GetObjectDart = int Function(Pointer<Void>, int, Pointer<_Bitmap>);

typedef _GetDIBitsNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Uint8>,
      Pointer<_BitmapInfo>,
      Uint32,
    );
typedef _GetDIBitsDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      int,
      Pointer<Uint8>,
      Pointer<_BitmapInfo>,
      int,
    );

typedef _DeleteObjectNative = Int32 Function(Pointer<Void>);
typedef _DeleteObjectDart = int Function(Pointer<Void>);

typedef _GetDCNative = Pointer<Void> Function(Pointer<Void>);
typedef _GetDCDart = Pointer<Void> Function(Pointer<Void>);

typedef _ReleaseDCNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _ReleaseDCDart = int Function(Pointer<Void>, Pointer<Void>);

/// `SIZE`：两个 LONG。Dart FFI 不自动补齐字段，这里全部显式声明。
final class _Size extends Struct {
  @Int32()
  external int cx;

  @Int32()
  external int cy;
}

/// `GUID`：4 + 2 + 2 + 8 字节。
final class _Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}

/// `BITMAP`（32 字节）：注意 WORD 之后有 4 字节填充，指针才对齐到 8 字节边界。
final class _Bitmap extends Struct {
  @Int32()
  external int bmType;

  @Int32()
  external int bmWidth;

  @Int32()
  external int bmHeight;

  @Int32()
  external int bmWidthBytes;

  @Uint16()
  external int bmPlanes;

  @Uint16()
  external int bmBitsPixel;

  @Array(4)
  external Array<Uint8> padding;

  external Pointer<Void> bmBits;
}

/// `BITMAPINFO`（44 字节）：BITMAPINFOHEADER 加一个 RGBQUAD 占位。
///
/// 明确展开为扁平结构，避免依赖嵌套 Struct 字段的写入行为。
final class _BitmapInfo extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  @Int32()
  external int biHeight;

  @Uint16()
  external int biPlanes;

  @Uint16()
  external int biBitCount;

  @Uint32()
  external int biCompression;

  @Uint32()
  external int biSizeImage;

  @Int32()
  external int biXPelsPerMeter;

  @Int32()
  external int biYPelsPerMeter;

  @Uint32()
  external int biClrUsed;

  @Uint32()
  external int biClrImportant;

  @Uint32()
  external int bmiColors;
}

/// `PROPERTYKEY`：GUID（16 字节）+ DWORD pid。
final class _PropertyKey extends Struct {
  @Array(16)
  external Array<Uint8> fmtid;

  @Uint32()
  external int pid;
}

/// `PROPVARIANT`（16 字节）：8 字节头部 + 8 字节联合体。
///
/// 只用到 `VT_UI4`，其值位于联合体起始的 4 字节（即偏移 8）。
final class _PropVariant extends Struct {
  @Uint16()
  external int vt;

  @Uint16()
  external int reserved1;

  @Uint16()
  external int reserved2;

  @Uint16()
  external int reserved3;

  @Uint32()
  external int uintValue;

  @Uint32()
  external int padding;
}

typedef _ShGetPropertyStoreNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Void>,
      Int32,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );
typedef _ShGetPropertyStoreDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Void>,
      int,
      Pointer<_Guid>,
      Pointer<Pointer<Void>>,
    );

typedef _GetValueNative =
    Int32 Function(Pointer<Void>, Pointer<_PropertyKey>, Pointer<_PropVariant>);
typedef _GetValueDart =
    int Function(Pointer<Void>, Pointer<_PropertyKey>, Pointer<_PropVariant>);
