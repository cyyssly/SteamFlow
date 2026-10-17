import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steam_flow/utils/rotated_fit.dart';

/// 同步返回固定尺寸图片的 [ImageProvider]。
///
/// 测试里的图片解码/读盘都是异步的，一来容易在不同环境挂起，
/// 二来与「布局尺寸」这个被测量对象无关；用同步提供器只保留待验证的布局行为。
class _FixedImageProvider extends ImageProvider<_FixedImageProvider> {
  _FixedImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_FixedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FixedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FixedImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
  );
}

/// 同步创建一张指定尺寸的图片。
ui.Image _makeImage(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  return picture.toImageSync(width, height);
}

void main() {
  group('layoutRotatedFitSize', () {
    // 用户的实际场景：3440×1440 的带鱼屏 + 720×1280 的竖图。
    const viewport = Size(3440, 1440);
    const portrait = Size(720, 1280);
    const landscape = Size(1280, 720);

    test('contain + 旋转 90° 时，图片短边占满屏幕短边', () {
      final size = layoutRotatedFitSize(
        intrinsic: portrait,
        viewport: viewport,
        fit: BoxFit.contain,
        quarterTurns: 1,
      );

      // 屏幕短边为 1440，旋转后图片的短边也必须贴满 1440。
      expect(size.shortestSide, closeTo(1440, 0.01));
      // 等比放大到极限：宽 2560 = 1440 * (1280 / 720)
      expect(size.width, closeTo(2560, 0.01));
      expect(size.height, closeTo(1440, 0.01));
    });

    test('未旋转时，contain 仍保持原有行为（长边贴满、短边留黑边）', () {
      final size = layoutRotatedFitSize(
        intrinsic: portrait,
        viewport: viewport,
        fit: BoxFit.contain,
        quarterTurns: 0,
      );

      expect(size.height, closeTo(1440, 0.01));
      expect(size.width, closeTo(810, 0.01));
    });

    test('旋转 90° 与 270° 结果一致，且 0/180 与未旋转一致', () {
      Size at(int turns) => layoutRotatedFitSize(
        intrinsic: portrait,
        viewport: viewport,
        fit: BoxFit.contain,
        quarterTurns: turns,
      );

      expect(at(1), at(3));
      expect(at(0), at(2));
    });

    test('任意旋转下都不会超出视口', () {
      for (final intrinsic in [portrait, landscape]) {
        for (final fit in [BoxFit.contain, BoxFit.cover, BoxFit.none]) {
          for (var turns = 0; turns < 4; turns++) {
            final size = layoutRotatedFitSize(
              intrinsic: intrinsic,
              viewport: viewport,
              fit: fit,
              quarterTurns: turns,
            );
            expect(
              size.width,
              lessThanOrEqualTo(viewport.width + 0.01),
              reason: 'fit=$fit turns=$turns',
            );
            expect(
              size.height,
              lessThanOrEqualTo(viewport.height + 0.01),
              reason: 'fit=$fit turns=$turns',
            );
          }
        }
      }
    });
  });

  group('normalizeQuarterTurns', () {
    test('把累加产生的浮点角度归一到 0~3', () {
      // 手动旋转会不断累加 π/2，误差随次数累积。
      double angle = 0;
      for (var i = 0; i < 12; i++) {
        expect(normalizeQuarterTurns(angle), i % 4);
        angle += 3.141592653589793 / 2;
      }
    });
  });

  testWidgets('RotatedBox + Image 在旋转后让图片短边贴满屏幕短边', (tester) async {
    const viewport = Size(344, 144);
    const fit = BoxFit.contain;
    const intrinsic = Size(72, 128);

    // 同步的假图片，避免真实文件解码带来的异步等待与挂起。
    final image = _makeImage(72, 128, const Color(0xFFC83C3C));
    addTearDown(image.dispose);
    final provider = _FixedImageProvider(image);

    for (var turns = 0; turns < 4; turns++) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: RotatedBox(
                quarterTurns: turns,
                child: Image(image: provider, fit: fit),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // RotatedBox 交给子级的约束盒：奇数圈时必须宽高互换（这就是修复的机制，
      // 也是 contain 能把短边填满的原因）。
      final childBox = tester.getSize(find.byType(Image));
      final expectedChildBox = turns.isOdd
          ? Size(viewport.height, viewport.width)
          : viewport;
      expect(
        childBox,
        expectedChildBox,
        reason: 'turns=$turns 旋转未发生在布局阶段（约束未翻转）',
      );

      // `Image` 占满约束盒，`fit` 只在绘制时留边；这里按真实绘制路径
      // （applyBoxFit）算出实际画出来的区域，再按旋转交换回屏幕方向。
      final paintedInChild = applyBoxFit(fit, intrinsic, childBox).destination;
      final paintedInScreen = turns.isOdd
          ? Size(paintedInChild.height, paintedInChild.width)
          : paintedInChild;

      // 与产品代码的几何算法保持一致。
      expect(
        paintedInScreen,
        layoutRotatedFitSize(
          intrinsic: intrinsic,
          viewport: viewport,
          fit: fit,
          quarterTurns: turns,
        ),
        reason: 'turns=$turns 几何算法与真实绘制结果不符',
      );

      // 用户可见的要求：旋转后图片短边必须贴满屏幕短边。
      if (turns.isOdd) {
        expect(
          paintedInScreen.shortestSide,
          closeTo(viewport.shortestSide, 0.01),
          reason: 'turns=$turns 旋转后短边未占满屏幕短边',
        );
      }
    }
  });
}
