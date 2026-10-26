import 'package:flutter/material.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 播放器右键菜单（自定义 Overlay 实现）。
///
/// 原生式级联菜单：一级菜单打开后保持显示，「播放速度」通过鼠标悬停或点击
/// 在其右侧展开二级菜单；点击具体档位（或一级操作项、菜单外任意位置）才整体
/// 关闭。相比两次顺序 [showMenu]（先关闭一级再弹出二级、各带一次路由动画），
/// 本组件只插入一个 OverlayEntry、90ms 淡入，弹出速度更快，交互也更接近系统。
class VideoContextMenu extends StatefulWidget {
  const VideoContextMenu({
    super.key,
    required this.anchor,
    required this.overlaySize,
    required this.l10n,
    required this.currentRate,
    required this.rates,
    required this.rateLabel,
    required this.onAction,
    required this.onRateSelected,
    required this.onClose,
  });

  /// 右键位置（Overlay 全局坐标），一级菜单左上角对齐到该点。
  final Offset anchor;

  /// 屏幕尺寸，用于把菜单限制在屏幕内。
  final Size overlaySize;

  final AppLocalizations l10n;

  /// 当前倍速，二级菜单中据此给当前档位打勾。
  final double currentRate;

  /// 倍速档位与文案。
  final List<double> rates;
  final String Function(double rate) rateLabel;

  /// 一级菜单操作（'zoomIn' / 'zoomOut' / 'fit' / 'rotate'）。
  final ValueChanged<String> onAction;

  /// 选中某个倍速档位。
  final ValueChanged<double> onRateSelected;

  /// 关闭整个菜单（外部点击、Esc、选择完成等）。
  final VoidCallback onClose;

  @override
  State<VideoContextMenu> createState() => _VideoContextMenuState();
}

class _VideoContextMenuState extends State<VideoContextMenu>
    with SingleTickerProviderStateMixin {
  /// 菜单淡入时长：尽量短，保证“秒开”手感。
  static const Duration _fadeInDuration = Duration(milliseconds: 90);

  /// 菜单与屏幕边缘的最小间距。
  static const double _screenPadding = 8.0;

  /// 菜单行高（与 PopupMenuItem 默认一致）。
  static const double _rowHeight = kMinInteractiveDimension;

  /// 「播放速度」行上方有 4 个操作项。
  static const int _rowsBeforeSpeedEntry = 4;

  late final AnimationController _fadeController;

  /// 实际渲染尺寸（布局后经 GlobalKey 测得），用于屏幕内定位与翻转。
  Size? _rootSize;
  Size? _subSize;

  /// 二级菜单展开状态：
  /// 悬停到「播放速度」行、悬停在二级菜单内、或点击行将其钉住（触控等无悬停场景）。
  bool _speedHovered = false;
  bool _submenuHovered = false;
  bool _speedPinned = false;

  bool get _speedOpen => _speedHovered || _submenuHovered || _speedPinned;

  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _subKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(vsync: this, duration: _fadeInDuration)
      ..forward();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndClamp());
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _setStateIfMounted(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// 布局完成后测量两个面板的实际尺寸并重新定位（边缘场景才真正位移）。
  void _measureAndClamp() {
    if (!mounted) return;
    var changed = false;
    final rootBox = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    if (rootBox != null && rootBox.hasSize) {
      final size = rootBox.size;
      if (_rootSize != size) {
        _rootSize = size;
        changed = true;
      }
    }
    if (_speedOpen) {
      final subBox = _subKey.currentContext?.findRenderObject() as RenderBox?;
      if (subBox != null && subBox.hasSize) {
        final size = subBox.size;
        if (_subSize != size) {
          _subSize = size;
          changed = true;
        }
      }
    }
    if (changed) setState(() {});
  }

  /// 把面板左上角收缩进屏幕（四周各留 [_screenPadding]）。
  Offset _clampToScreen(Offset topLeft, Size panel) {
    var x = topLeft.dx;
    if (x + panel.width > widget.overlaySize.width - _screenPadding) {
      x = widget.overlaySize.width - panel.width - _screenPadding;
    }
    if (x < _screenPadding) x = _screenPadding;

    var y = topLeft.dy;
    if (y + panel.height > widget.overlaySize.height - _screenPadding) {
      y = widget.overlaySize.height - panel.height - _screenPadding;
    }
    if (y < _screenPadding) y = _screenPadding;
    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    // 一级菜单锚定到右键位置；测到实际尺寸后按屏幕边界收缩。
    final rootPos = _rootSize == null
        ? widget.anchor
        : _clampToScreen(widget.anchor, _rootSize!);

    return Positioned.fill(
      // 不透明命中屏障：吃掉菜单外的点击，不让事件漏到下面的视频层
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        onSecondaryTapUp: (_) => widget.onClose(),
        child: Stack(
          children: [
            Positioned(
              left: rootPos.dx,
              top: rootPos.dy,
              child: FadeTransition(
                opacity: _fadeController,
                child: _buildRootMenu(),
              ),
            ),
            if (_speedOpen) _buildSubmenu(rootPos),
          ],
        ),
      ),
    );
  }

  Widget _buildRootMenu() {
    final theme = PopupMenuTheme.of(context);
    return Material(
      key: _rootKey,
      color: theme.color,
      elevation: theme.elevation ?? 8.0,
      shape: theme.shape,
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle(
        // 正常菜单字号：M3 默认的 titleMedium（16px/w500）偏大，
        // 用 bodyMedium（14px 常规）更接近系统右键菜单的观感
        style: theme.textStyle ?? Theme.of(context).textTheme.bodyMedium!,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _menuItemRow(
              label: widget.l10n.zoomIn,
              onTap: () => widget.onAction('zoomIn'),
            ),
            _menuItemRow(
              label: widget.l10n.zoomOut,
              onTap: () => widget.onAction('zoomOut'),
            ),
            _menuItemRow(
              label: widget.l10n.fitScreen,
              onTap: () => widget.onAction('fit'),
            ),
            _menuItemRow(
              label: widget.l10n.rotate,
              onTap: () => widget.onAction('rotate'),
            ),
            // 不加分隔条：所有行统一 48px 高，保证间距一致；
            // 「播放速度」用右侧箭头表明是二级菜单入口
            _buildSpeedEntryRow(),
          ],
        ),
      ),
    );
  }

  Widget _menuItemRow({required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(alignment: Alignment.centerLeft, child: Text(label)),
        ),
      ),
    );
  }

  /// 「播放速度」入口行：悬停或点击展开二级菜单，一级菜单保持不关闭。
  Widget _buildSpeedEntryRow() {
    return MouseRegion(
      onEnter: (_) => _setStateIfMounted(() => _speedHovered = true),
      onExit: (_) => _setStateIfMounted(() => _speedHovered = false),
      child: InkWell(
        onTap: () => _setStateIfMounted(() => _speedPinned = !_speedPinned),
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.l10n.playbackSpeed),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 二级菜单：紧贴「播放速度」行右侧展开，放不下时翻转到左侧。
  Widget _buildSubmenu(Offset rootPos) {
    final theme = PopupMenuTheme.of(context);
    // 一级菜单右缘、入口行行顶（上方 4 行 × 48）。
    final rootWidth = _rootSize?.width ?? 0.0;
    final entryRowTop = _rowsBeforeSpeedEntry * _rowHeight;
    final subSize = _subSize;

    var topLeft = rootPos + Offset(rootWidth, entryRowTop);
    if (subSize != null) {
      // 右侧放不下且翻到左侧仍够放时，翻转到一级菜单左侧展开。
      final fitsRight = topLeft.dx + subSize.width <=
          widget.overlaySize.width - _screenPadding;
      final fitsLeft = rootPos.dx - subSize.width >= _screenPadding;
      if (!fitsRight && fitsLeft) {
        topLeft = Offset(rootPos.dx - subSize.width, topLeft.dy);
      }
      topLeft = _clampToScreen(topLeft, subSize);
    }

    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      child: MouseRegion(
        onEnter: (_) => _setStateIfMounted(() => _submenuHovered = true),
        onExit: (_) => _setStateIfMounted(() => _submenuHovered = false),
        child: Material(
          key: _subKey,
          color: theme.color,
          elevation: theme.elevation ?? 8.0,
          shape: theme.shape,
          clipBehavior: Clip.antiAlias,
          child: DefaultTextStyle(
            // 与一级菜单一致的正常字号
            style: theme.textStyle ?? Theme.of(context).textTheme.bodyMedium!,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final rate in widget.rates)
                  InkWell(
                    onTap: () => widget.onRateSelected(rate),
                    child: SizedBox(
                      height: _rowHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              child: widget.currentRate == rate
                                  ? const Icon(
                                      Icons.check,
                                      size: 16,
                                      color: Color(0xFFe94560),
                                    )
                                  : null,
                            ),
                            Text(widget.rateLabel(rate)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
