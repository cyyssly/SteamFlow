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

typedef _StrCmpLogicalWNative =
    Int32 Function(Pointer<Utf16> psz1, Pointer<Utf16> psz2);
typedef _StrCmpLogicalWDart =
    int Function(Pointer<Utf16> psz1, Pointer<Utf16> psz2);

// 惰性初始化：DLL 与函数指针只解析一次。
// 之前每次比较都重新 open + lookupFunction，大量视频排序要做数十万次比较，
// 仅这一项固定开销就非常可观。
final _StrCmpLogicalWDart _strCmpLogicalWFn = DynamicLibrary.open(
  'shlwapi.dll',
).lookupFunction<_StrCmpLogicalWNative, _StrCmpLogicalWDart>('StrCmpLogicalW');

int _strCmpLogical(String a, String b) {
  final aPtr = a.toNativeUtf16();
  final bPtr = b.toNativeUtf16();
  try {
    // StrCmpLogicalW 返回值：负数 a<b，0 相等，正数 a>b
    return _strCmpLogicalWFn(aPtr, bPtr);
  } finally {
    calloc.free(aPtr);
    calloc.free(bPtr);
  }
}

// ==================== 非 Windows: 自然排序 ====================

int _naturalCompare(String a, String b) {
  return _compareNaturalKeys(_splitNaturalLower(a), _splitNaturalLower(b));
}

/// 比较两个预分段键：文本段已预小写化，比较时不再分配新字符串
int _compareNaturalKeys(List<Object> partsA, List<Object> partsB) {
  final len = partsA.length < partsB.length ? partsA.length : partsB.length;
  for (int i = 0; i < len; i++) {
    final pa = partsA[i];
    final pb = partsB[i];
    int result;
    if (pa is int && pb is int) {
      result = pa.compareTo(pb);
    } else if (pa is String && pb is String) {
      result = pa.compareTo(pb);
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

// ==================== 批量排序：预转换比较键 ====================

/// 预分段并小写化文本段，作为非 Windows 平台的排序键
List<Object> _splitNaturalLower(String s) {
  final parts = _splitNatural(s);
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part is String) parts[i] = part.toLowerCase();
  }
  return parts;
}

Object _makeSortKey(String name) {
  if (Platform.isWindows) return name.toNativeUtf16();
  return _splitNaturalLower(name);
}

int _compareKeys(Object a, Object b) {
  if (Platform.isWindows) {
    return _strCmpLogicalWFn(a as Pointer<Utf16>, b as Pointer<Utf16>);
  }
  return _compareNaturalKeys(a as List<Object>, b as List<Object>);
}

/// 按文件名对 [items] 批量排序（规则与 [compareFileNames] 一致）。
///
/// 先把每个文件名一次性转换成比较键再排序（装饰-排序-去装饰）：
/// 大列表排序要做约 n·log n 次比较，逐对调用 [compareFileNames] 时
/// 每次都要重新转换字符串并分配内存，而按键比较不再有任何分配，
/// 这是大目录排序从数秒降到百毫秒级的关键。
void sortByFileName<T>(
  List<T> items,
  String Function(T) nameOf, {
  bool descending = false,
}) {
  final length = items.length;
  if (length < 2) return;
  final keys = <Object>[for (final item in items) _makeSortKey(nameOf(item))];
  try {
    final order = List<int>.generate(length, (i) => i);
    order.sort((a, b) {
      final result = _compareKeys(keys[a], keys[b]);
      return descending ? -result : result;
    });
    final sorted = [for (final index in order) items[index]];
    items.setAll(0, sorted);
  } finally {
    // Windows 的键是原生内存，必须显式释放
    for (final key in keys) {
      if (key is Pointer) calloc.free(key);
    }
  }
}
