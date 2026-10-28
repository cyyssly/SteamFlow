import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 播放器右键菜单（自定义 Overlay 实现）。
///
/// 原生式级联菜单：一级菜单打开后保持显示，「播放速度」「声道」「字幕」
/// 通过鼠标悬停或点击在其右侧展开二级菜单；点击具体档位（或一级操作项、
/// 菜单外任意位置）才整体关闭。相比两次顺序 [showMenu]（先关闭一级再弹出二级、
/// 各带一次路由动画），本组件只插入一个 OverlayEntry、90ms 淡入，
/// 弹出速度更快，交互也更接近系统。
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
    this.tracks,
    this.currentTrack,
    this.onAudioTrackSelected,
    this.onSubtitleTrackSelected,
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

  /// 当前媒体可用的音轨与字幕轨道。
  /// 为 null 或列表为空时不显示「声道/字幕」入口行。
  final Tracks? tracks;

  /// 当前选中的音轨/字幕，用来在二级菜单里打勾。
  final Track? currentTrack;

  /// 用户切换音轨；为 null 时「声道」入口不显示。
  final ValueChanged<AudioTrack>? onAudioTrackSelected;

  /// 用户切换字幕；为 null 时「字幕」入口不显示。
  final ValueChanged<SubtitleTrack>? onSubtitleTrackSelected;

  @override
  State<VideoContextMenu> createState() => _VideoContextMenuState();
}

class _VideoContextMenuState extends State<VideoContextMenu>
    with SingleTickerProviderStateMixin {
  /// 菜单淡入时长：尽量短，保证"秒开"手感。
  static const Duration _fadeInDuration = Duration(milliseconds: 90);

  /// 菜单与屏幕边缘的最小间距。
  static const double _screenPadding = 8.0;

  /// 菜单行高。
  /// 默认的 kMinInteractiveDimension（48）在移动端显得行间距偏大，收窄到 40。
  static const double _rowHeight = 40.0;

  /// 级联入口行在 Column 里的相对顺序：
  /// 3 个操作项（放大/缩小/旋转）+ 播放速度 + 声道 + 字幕。
  /// 此常量只用于计算二级菜单锚点位置。
  static const int _rowsBeforeCascade = 3;

  late final AnimationController _fadeController;

  /// 实际渲染尺寸（布局后经 GlobalKey 测得），用于屏幕内定位与翻转。
  Size? _rootSize;
  Size? _speedSubSize;
  Size? _audioSubSize;
  Size? _subtitleSubSize;

  /// 当前正在展开的级联子菜单（'speed' / 'audio' / 'subtitle' / null）。
  String? _activeCascade;

  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _speedSubKey = GlobalKey();
  final GlobalKey _audioSubKey = GlobalKey();
  final GlobalKey _subtitleSubKey = GlobalKey();

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

  /// 布局完成后测量所有面板尺寸并重新定位。
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

    if (_activeCascade == 'speed') {
      final box = _speedSubKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        if (_speedSubSize != box.size) {
          _speedSubSize = box.size;
          changed = true;
        }
      }
    }
    if (_activeCascade == 'audio') {
      final box = _audioSubKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        if (_audioSubSize != box.size) {
          _audioSubSize = box.size;
          changed = true;
        }
      }
    }
    if (_activeCascade == 'subtitle') {
      final box =
          _subtitleSubKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        if (_subtitleSubSize != box.size) {
          _subtitleSubSize = box.size;
          changed = true;
        }
      }
    }

    if (changed) setState(() {});
  }

  /// 把面板左上角收缩进屏幕（四周各留 [_screenPadding]）。
  /// 播放页是沉浸式全屏，菜单层会铺到导航栏/状态栏/挖孔区域下面，
  /// 所以边界还要再让出系统安全区，否则贴底的菜单会被导航栏盖住一截。
  Offset _clampToScreen(Offset topLeft, Size panel) {
    final insets = MediaQuery.viewPaddingOf(context);
    final leftBound = _screenPadding + insets.left;
    final topBound = _screenPadding + insets.top;
    final rightBound = widget.overlaySize.width - _screenPadding - insets.right;
    final bottomBound =
        widget.overlaySize.height - _screenPadding - insets.bottom;

    var x = topLeft.dx;
    if (x + panel.width > rightBound) x = rightBound - panel.width;
    if (x < leftBound) x = leftBound;

    var y = topLeft.dy;
    if (y + panel.height > bottomBound) y = bottomBound - panel.height;
    if (y < topBound) y = topBound;
    return Offset(x, y);
  }

  /// 展开/折叠级联菜单。同一时刻只允许一个子菜单展开，
  /// 点击或悬停新入口会自动收起旧的。
  void _openCascade(String name) {
    final willOpen = _activeCascade != name;
    _setStateIfMounted(() {
      _activeCascade = willOpen ? name : null;
    });
    // 二级菜单是本次 setState 才挂上去的，尺寸还没量过 → 定位时无法判断是否需要
    // 避让屏幕边缘。横屏下高度只有 ~390dp，播放速度子菜单会比可用高度还靠下，
    // 不量尺寸就会被切掉底部，所以展开后补一次测量。
    if (willOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndClamp());
    }
  }

  void _closeCascade() {
    _setStateIfMounted(() => _activeCascade = null);
  }

  @override
  Widget build(BuildContext context) {
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
            if (_activeCascade == 'speed')
              _buildTrackSubmenu(
                rootPos: rootPos,
                rowIndex: _rowIndexOfSpeed,
                subSize: _speedSubSize,
                subKey: _speedSubKey,
                items: widget.rates
                    .map((r) => _TrackMenuItem(
                          id: r.toString(),
                          label: widget.rateLabel(r),
                          isSelected: widget.currentRate == r,
                          onTap: () {
                            _closeCascade();
                            widget.onRateSelected(r);
                          },
                        ))
                    .toList(),
              ),
            if (_activeCascade == 'audio' &&
                widget.tracks != null &&
                widget.onAudioTrackSelected != null)
              _buildTrackSubmenu(
                rootPos: rootPos,
                rowIndex: _rowIndexOfAudio,
                subSize: _audioSubSize,
                subKey: _audioSubKey,
                items: _realAudioTracks
                    .map((t) => _TrackMenuItem(
                          id: t.id,
                          label: _audioTrackLabel(t),
                          isSelected: _selectedAudioId == t.id,
                          onTap: () {
                            _closeCascade();
                            widget.onAudioTrackSelected!(t);
                          },
                        ))
                    .toList(),
              ),
            if (_activeCascade == 'subtitle' &&
                widget.tracks != null &&
                widget.onSubtitleTrackSelected != null)
              _buildTrackSubmenu(
                rootPos: rootPos,
                rowIndex: _rowIndexOfSubtitle,
                subSize: _subtitleSubSize,
                subKey: _subtitleSubKey,
                items: _realSubtitleTracks
                    .map((t) => _TrackMenuItem(
                          id: t.id,
                          label: _subtitleTrackLabel(t),
                          isSelected: _selectedSubtitleId == t.id,
                          onTap: () {
                            _closeCascade();
                            widget.onSubtitleTrackSelected!(t);
                          },
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  /// 动态计算每个级联入口行的相对位置（前面有哪些行才决定它是第几行）。
  int get _rowIndexOfSpeed => _rowsBeforeCascade;

  /// 播放器内置的 `auto` / `no` 特殊轨道 id。
  static bool _isSpecialTrackId(String id) => id == 'auto' || id == 'no';

  /// 可选音轨：去掉「自动」与「关闭」（关闭声音用音量按钮即可）
  List<AudioTrack> get _realAudioTracks =>
      (widget.tracks?.audio ?? const <AudioTrack>[])
          .where((t) => !_isSpecialTrackId(t.id))
          .toList();

  /// 可选字幕：去掉「自动」，保留「关闭」
  List<SubtitleTrack> get _realSubtitleTracks =>
      (widget.tracks?.subtitle ?? const <SubtitleTrack>[])
          .where((t) => t.id != 'auto')
          .toList();

  /// 当前生效的音轨 id：播放器处于 `auto` 时按默认行为（第一条真实音轨）判定
  String? get _selectedAudioId {
    final id = widget.currentTrack?.audio.id;
    if (id == null || id == 'no') return null;
    if (id != 'auto') return id;
    final tracks = _realAudioTracks;
    return tracks.isEmpty ? null : tracks.first.id;
  }

  /// 当前生效的字幕 id：`auto` 时回退到第一条真实字幕，`no` 即「关闭」项
  String? get _selectedSubtitleId {
    final id = widget.currentTrack?.subtitle.id;
    if (id == null) return null;
    if (id == 'no') return 'no';
    if (id != 'auto') return id;
    final real = _realSubtitleTracks.where((t) => t.id != 'no');
    return real.isEmpty ? null : real.first.id;
  }

  /// 声道入口是否实际渲染：需有回调、且真实音轨 > 1 条
  bool get _audioVisible {
    if (widget.onAudioTrackSelected == null) return false;
    return _realAudioTracks.length > 1;
  }

  /// 字幕入口是否实际渲染：需有回调、且有真实字幕
  bool get _subtitleVisible {
    if (widget.onSubtitleTrackSelected == null) return false;
    return _realSubtitleTracks.any((t) => t.id != 'no');
  }

  int get _rowIndexOfAudio => _audioVisible ? _rowIndexOfSpeed + 1 : -1;
  int get _rowIndexOfSubtitle =>
      _subtitleVisible
          ? _rowIndexOfSpeed + 1 + (_audioVisible ? 1 : 0)
          : -1;

  String _audioTrackLabel(AudioTrack t) {
    final name = t.title ?? t.language ?? t.codec ?? t.id;
    final chan = t.channels;
    if (chan != null && chan.isNotEmpty) return '$name · $chan';
    return name;
  }

  String _subtitleTrackLabel(SubtitleTrack t) {
    if (t.id == 'no') return widget.l10n.subtitleOff;
    return t.title ?? t.language ?? t.codec ?? t.id;
  }

  Widget _buildRootMenu() {
    final theme = PopupMenuTheme.of(context);
    final children = <Widget>[
      _menuItemRow(
        label: widget.l10n.zoomIn,
        onTap: () => widget.onAction('zoomIn'),
      ),
      _menuItemRow(
        label: widget.l10n.zoomOut,
        onTap: () => widget.onAction('zoomOut'),
      ),
      _menuItemRow(
        label: widget.l10n.rotate,
        onTap: () => widget.onAction('rotate'),
      ),
      _buildCascadeEntry(
        label: widget.l10n.playbackSpeed,
        isOpen: _activeCascade == 'speed',
        onHover: () => _openCascade('speed'),
      ),
    ];
    // 声道入口：真实音轨 > 1 条时才有选择价值，否则音量按钮足够
    if (_audioVisible) {
      children.add(
        _buildCascadeEntry(
          label: widget.l10n.audioTrack,
          isOpen: _activeCascade == 'audio',
          onHover: () => _openCascade('audio'),
        ),
      );
    }
    // 字幕入口：存在真实内嵌字幕时才显示
    if (_subtitleVisible) {
      children.add(
        _buildCascadeEntry(
          label: widget.l10n.subtitleTrack,
          isOpen: _activeCascade == 'subtitle',
          onHover: () => _openCascade('subtitle'),
        ),
      );
    }

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
          children: children,
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

  /// 级联入口行：悬停展开、点击钉住再点击关闭。
  Widget _buildCascadeEntry({
    required String label,
    required bool isOpen,
    required VoidCallback onHover,
  }) {
    return MouseRegion(
      onEnter: (_) => onHover(),
      // 鼠标离开入口行也不要立刻收起，让用户有时间移动到二级菜单
      // （MouseRegion 包裹的是整个 InkWell 行，onExit 留空）
      child: InkWell(
        onTap: () => onHover(),
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: isOpen
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 通用的级联二级菜单：紧贴入口行右侧展开，放不下时翻转到左侧。
  Widget _buildTrackSubmenu({
    required Offset rootPos,
    required int rowIndex,
    required Size? subSize,
    required GlobalKey subKey,
    required List<_TrackMenuItem> items,
  }) {
    final theme = PopupMenuTheme.of(context);
    final rootWidth = _rootSize?.width ?? 0.0;
    final entryRowTop = rowIndex * _rowHeight;

    var topLeft = rootPos + Offset(rootWidth, entryRowTop);
    if (subSize != null) {
      final insets = MediaQuery.viewPaddingOf(context);
      final fitsRight = topLeft.dx + subSize.width <=
          widget.overlaySize.width - _screenPadding - insets.right;
      final fitsLeft =
          rootPos.dx - subSize.width >= _screenPadding + insets.left;
      if (!fitsRight && fitsLeft) {
        topLeft = Offset(rootPos.dx - subSize.width, topLeft.dy);
      }
      topLeft = _clampToScreen(topLeft, subSize);
    }

    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      child: MouseRegion(
        onEnter: (_) {
          // 进入二级菜单时保持当前级联打开
        },
        onExit: (_) {
          // 离开二级菜单（同时不在入口行）时关闭
          if (mounted) setState(() => _activeCascade = null);
        },
        child: Material(
          key: subKey,
          color: theme.color,
          elevation: theme.elevation ?? 8.0,
          shape: theme.shape,
          clipBehavior: Clip.antiAlias,
          child: DefaultTextStyle(
            style: theme.textStyle ?? Theme.of(context).textTheme.bodyMedium!,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  InkWell(
                    onTap: item.onTap,
                    child: SizedBox(
                      height: _rowHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              child: item.isSelected
                                  ? const Icon(
                                      Icons.check,
                                      size: 16,
                                      color: Color(0xFFe94560),
                                    )
                                  : null,
                            ),
                            Text(item.label),
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

/// 二级菜单项的通用数据载体
class _TrackMenuItem {
  final String id;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackMenuItem({
    required this.id,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });
}
