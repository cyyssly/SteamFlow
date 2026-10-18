import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

/// 视频首帧缩略图。
///
/// [bytes] 为 PNG 编码后的字节，[width] / [height] 是真实帧尺寸
/// （不含任何裁剪或留黑边），可直接用于推导宽高比。
class VideoThumbnail {
  final Uint8List bytes;
  final int width;
  final int height;

  const VideoThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
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
    return VideoThumbnail(
      bytes: Uint8List.fromList(img.encodePng(frame)),
      width: width,
      height: height,
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
