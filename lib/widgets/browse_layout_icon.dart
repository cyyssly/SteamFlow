import 'package:flutter/material.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/settings_provider.dart';

/// 浏览格式示意图标：用卡片形状直观表示瀑布流或固定画幅。
///
/// 与 [SortAlphabetIcon] 一样，避免使用含义模糊的 Material 图标
/// （例如竖屏 3:4 与 9:16 没有现成的区分图标）。
class BrowseLayoutIcon extends StatelessWidget {
  final BrowseLayout layout;
  final Color color;

  const BrowseLayoutIcon({
    super.key,
    required this.layout,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _BrowseLayoutPainter(layout: layout, color: color),
    );
  }
}

/// 浏览格式下拉菜单：本地与共享浏览页共用。
class BrowseLayoutMenuButton extends StatelessWidget {
  final BrowseLayout value;
  final ValueChanged<BrowseLayout> onSelected;

  const BrowseLayoutMenuButton({
    super.key,
    required this.value,
    required this.onSelected,
  });

  static const Color _activeColor = Color(0xFFe94560);

  String _label(AppLocalizations loc, BrowseLayout layout) {
    return switch (layout) {
      BrowseLayout.masonry => loc.browseLayoutMasonry,
      BrowseLayout.square => loc.browseLayoutSquare,
      BrowseLayout.landscape4x3 => loc.browseLayoutLandscape4x3,
      BrowseLayout.landscape16x9 => loc.browseLayoutLandscape16x9,
      BrowseLayout.portrait3x4 => loc.browseLayoutPortrait3x4,
      BrowseLayout.portrait9x16 => loc.browseLayoutPortrait9x16,
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopupMenuButton<BrowseLayout>(
      tooltip: loc.browseLayout,
      icon: BrowseLayoutIcon(layout: value, color: Colors.white70),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final layout in BrowseLayout.values)
          PopupMenuItem<BrowseLayout>(
            value: layout,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: BrowseLayoutIcon(
                      layout: layout,
                      color: layout == value ? _activeColor : Colors.white70,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_label(loc, layout))),
                if (layout == value)
                  const Icon(Icons.check, color: _activeColor, size: 18),
              ],
            ),
          ),
      ],
    );
  }
}

class _BrowseLayoutPainter extends CustomPainter {
  final BrowseLayout layout;
  final Color color;

  _BrowseLayoutPainter({required this.layout, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;

    // 瀑布流用三块高低不同的卡片表示；固定画幅用居中缩放的矩形表示
    if (layout == BrowseLayout.masonry) {
      _tile(canvas, paint, const Rect.fromLTWH(3, 3, 8, 10));
      _tile(canvas, paint, const Rect.fromLTWH(3, 15, 8, 6));
      _tile(canvas, paint, const Rect.fromLTWH(13, 3, 8, 18));
      return;
    }

    const area = Rect.fromLTWH(3, 3, 18, 18);
    final ratio = layout.aspectRatio ?? 1.0;
    final double width;
    final double height;
    if (ratio >= 1) {
      width = area.width;
      height = area.width / ratio;
    } else {
      height = area.height;
      width = area.height * ratio;
    }
    _tile(
      canvas,
      paint,
      Rect.fromCenter(center: area.center, width: width, height: height),
    );
  }

  void _tile(Canvas canvas, Paint paint, Rect rect) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _BrowseLayoutPainter oldDelegate) =>
      oldDelegate.layout != layout || oldDelegate.color != color;
}
