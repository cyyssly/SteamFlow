import 'package:flutter/material.dart';

/// “A-Z / Z-A”样式的排序图标。
///
/// 瀑布流页面里，按名称的顺序/逆序如果继续用上下箭头，
/// 会和按文件大小的最大/最小箭头过于相似；这里改用上下排列的字母，
/// 升序显示 A→Z 的堆叠，降序显示 Z→A，一眼即可与大小排序区分开。
class SortAlphabetIcon extends StatelessWidget {
  /// true 表示顺序（A 在上、Z 在下），false 表示逆序（Z 在上、A 在下）
  final bool ascending;

  /// 图标颜色，由调用方根据激活状态传入
  final Color color;

  const SortAlphabetIcon({
    super.key,
    required this.ascending,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 10,
      height: 1.0,
      fontWeight: FontWeight.w700,
      color: color,
      letterSpacing: 0,
    );
    return SizedBox(
      width: 24,
      height: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(ascending ? 'A' : 'Z', style: style),
          Text(ascending ? 'Z' : 'A', style: style),
        ],
      ),
    );
  }
}
