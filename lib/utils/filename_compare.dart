import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// 文件名比较器：
/// - **Windows**：调用系统 `StrCmpLogicalW`（资源管理器同款排序），
///   中文按拼音字母序、数字按数值、大小写不敏感。
/// - **其他平台**：纯 Dart 自然排序（中文仍按 Unicode 码点）。
///
/// 完全替换 Dart 默认的 [String.compareTo]，后者按 Unicode code point
/// 排序，会把中文「吧(U+5427)」排在「啊(U+554A)」前面——拼音应该是
/// 啊(a) < 吧(ba) < 茶(cha)。

int compareFileNames(String a, String b) {
  if (Platform.isWindows) return _strCmpLogical(a, b);
  return _naturalCompare(a, b);
}

// ==================== Windows: StrCmpLogicalW ====================

typedef _StrCmpLogicalWNative = Int32 Function(
  Pointer<Utf16> psz1,
  Pointer<Utf16> psz2,
);
typedef _StrCmpLogicalWDart = int Function(
  Pointer<Utf16> psz1,
  Pointer<Utf16> psz2,
);

int _strCmpLogical(String a, String b) {
  final dll = DynamicLibrary.open('shlwapi.dll');
  final fn =
      dll
          .lookupFunction<_StrCmpLogicalWNative, _StrCmpLogicalWDart>(
            'StrCmpLogicalW',
          );

  final aPtr = a.toNativeUtf16();
  final bPtr = b.toNativeUtf16();
  try {
    final result = fn(aPtr, bPtr);
    // StrCmpLogicalW 返回值：负数 a<b，0 相等，正数 a>b
    return result;
  } finally {
    calloc.free(aPtr);
    calloc.free(bPtr);
  }
}

// ==================== 非 Windows: 自然排序 ====================

int _naturalCompare(String a, String b) {
  final partsA = _splitNatural(a);
  final partsB = _splitNatural(b);
  final len = partsA.length < partsB.length ? partsA.length : partsB.length;
  for (int i = 0; i < len; i++) {
    final pa = partsA[i];
    final pb = partsB[i];
    int result;
    if (pa is int && pb is int) {
      result = pa.compareTo(pb);
    } else if (pa is String && pb is String) {
      result = pa.toLowerCase().compareTo(pb.toLowerCase());
    } else {
      // 一段是数字一段是字符串：数字排在字符串前面
      result = (pa is int ? -1 : 1);
    }
    if (result != 0) return result;
  }
  return partsA.length.compareTo(partsB.length);
}

/// 按自然排序规则切分字符串：
/// "video10.mp4" → ["video", 10, ".mp4"]
List<Object> _splitNatural(String s) {
  final result = <Object>[];
  final buffer = StringBuffer();
  int? numBuffer;
  void flushText() {
    if (buffer.isNotEmpty) {
      result.add(buffer.toString());
      buffer.clear();
    }
  }

  for (int i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) {
      // 数字
      if (buffer.isNotEmpty) {
        flushText();
      }
      final digit = c - 0x30;
      numBuffer = (numBuffer ?? 0) * 10 + digit;
    } else {
      // 非数字
      if (numBuffer != null) {
        result.add(numBuffer);
        numBuffer = null;
      }
      buffer.writeCharCode(c);
    }
  }
  if (numBuffer != null) result.add(numBuffer);
  if (buffer.isNotEmpty) flushText();
  return result;
}
