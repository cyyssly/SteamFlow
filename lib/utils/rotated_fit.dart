import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// 把任意浮点角度归一化为 0~3 的 90° 圈数。
///
/// 手动旋转累加 `math.pi / 2` 会引入浮点误差（三次之后尤其明显），
/// 统一转成整数圈数交给 [RotatedBox]，从根上避免累积误差。
int normalizeQuarterTurns(double radians) {
  final turns = (radians / (math.pi / 2)).round();
  return (turns % 4 + 4) % 4;
}

/// 计算「布局阶段旋转」后，视频在屏幕上占据的尺寸（未缩放）。
///
/// [RotatedBox] 在布局时会把父级约束**沿对角翻转**再交给子级，因此这里的
/// 算法必须与之完全一致：
///
/// 1. 90°/270° 时先把视口宽高互换，得到子级实际拿到的约束；
/// 2. 在该约束下按 [fit] 做一次适配；
/// 3. 再把适配结果交换回来，就是旋转后占据的屏幕矩形。
///
/// 直接对「未旋转视口下适配好的尺寸」做交换是**错误**的：
/// 以 3440×1440 视口中的 1080×1920 竖图为例，
/// `contain` 直算得 810×1440，交换后变成 1440×810 —— 短边只剩 810，
/// 这正是「旋转后短边没占满屏幕」的由来；而真实渲染（先翻转视口再适配）
/// 得到 2560×1440，短边 1440 恰好填满。
Size layoutRotatedFitSize({
  required Size intrinsic,
  required Size viewport,
  required BoxFit fit,
  required int quarterTurns,
}) {
  if (intrinsic.isEmpty || viewport.isEmpty) return Size.zero;

  final turns = (quarterTurns % 4 + 4) % 4;
  final isVertical = turns.isOdd;

  // 布局阶段旋转会先翻转约束，再交给子级适配。
  final outer = isVertical ? Size(viewport.height, viewport.width) : viewport;
  final fitted = applyBoxFit(fit, intrinsic, outer).destination;

  return isVertical ? Size(fitted.height, fitted.width) : fitted;
}
