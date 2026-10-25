import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('托盘图标包含多尺寸帧', () {
    final bytes = File('assets/icon/tray_icon.ico').readAsBytesSync();
    expect(bytes.length, greaterThan(10000));
    // ICONDIR: reserved=0, type=1(icon), count
    expect(bytes[0], 0);
    expect(bytes[1], 0);
    expect(bytes[2], 1);
    expect(bytes[3], 0);
    final count = bytes[4] | (bytes[5] << 8);
    expect(count, 9);

    final sizes = <int>[];
    for (var i = 0; i < count; i++) {
      final offset = 6 + i * 16;
      final width = bytes[offset] == 0 ? 256 : bytes[offset];
      final height = bytes[offset + 1] == 0 ? 256 : bytes[offset + 1];
      expect(width, height);
      sizes.add(width);
    }
    expect(sizes, [16, 20, 24, 32, 40, 48, 64, 128, 256]);
  });
}
