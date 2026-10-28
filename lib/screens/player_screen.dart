import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/models/video_item.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/services/desktop_tray_service.dart';
import 'package:steam_flow/services/fullscreen_service.dart';
import 'package:steam_flow/services/lan_client_service.dart';
import 'package:steam_flow/services/playback_progress_service.dart';
import 'package:steam_flow/services/remote_copy_service.dart';
import 'package:steam_flow/services/track_pref_service.dart';
import 'package:steam_flow/utils/rotated_fit.dart';
import 'package:steam_flow/widgets/video_context_menu.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:wakelock_plus/wakelock_plus.dart';

/// 单指手势的轴向：横向 = 拖动进度，纵向 = 切换视频。
enum _SwipeAxis { none, horizontal, vertical }

/// 换片动画的触发来源，用于自动选择动画方向。
enum _TransitionTrigger {
  vertical, // 滚轮、手势等手动切换：上下滑动
  horizontal, // 工具栏按钮、方向键：左右滑动
  auto, // 播放结束自动切换：淡入淡出
}

/// 缩放/平移的绘制快照（只驱动 [Transform] 子树重建）。
class _ViewTransform {
  final double scale;
  final Offset position;
  const _ViewTransform({required this.scale, required this.position});
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  // ==================== 播放内核 ====================
  late final Player _player;
  late final VideoController _videoController;

  /// 全局唯一的活动播放器。
  ///
  /// 正常路径下每个播放页都会在 [dispose] 里销毁自己的播放器；但若某条退出
  /// 路径没能及时销毁页面（例如路由被保留），旧播放器会继续在后台出声。
  /// 新播放页创建播放器时先销毁上一个实例，保证同时只有一个视频在播放。
  static Player? _activePlayer;

  /// 缓存的播放列表中枢：路由弹出回调与 dispose 中不能再可靠地查找 Provider。
  late final SlideProvider _slideProvider;

  /// 本次退出是否已经停过播放，避免退出路径与路由弹出回调重复触发停止。
  bool _stoppedForExit = false;

  /// 由播放器事件流维护的状态快照
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  Duration _videoPosition = Duration.zero;
  Duration _videoDuration = Duration.zero;
  int? _videoWidth;
  int? _videoHeight;
  String? _playbackError;

  /// 进入本页时是否已经处于全屏。
  ///
  /// 从瀑布流页直接进播放时，全屏可能是瀑布流自己（F11）开的；退出播放时必须
  /// 按进入前的状态还原：进入前是全屏就保持全屏（否则会把瀑布流的全屏一并吃
  /// 掉），进入前是窗口才还原窗口尺寸与位置。
  bool _wasFullscreenBeforePlayback = false;

  /// 进度拖拽（进度条或横向滑动）中的预览位置；非 null 时优先显示它
  Duration? _seekPreview;

  /// 播放器音量（0~100）。工具栏音量图标的形态与滑杆值都取自它。
  double _volume = 100;

  /// 当前播放速度（倍速）。手机端工具栏与桌面右键菜单均可切换。
  double _playbackRate = 1.0;

  /// 右键菜单当前是否打开，以及对应的 OverlayEntry（供 ESC/外部点击关闭）。
  bool _contextMenuOpen = false;
  OverlayEntry? _contextMenuEntry;

  /// 当前视频的音轨 / 字幕轨道（由 stream.tracks 维护）
  Tracks? _tracks;
  Track? _currentTrack;

  /// 工具栏菜单按钮的位置引用（用于定位弹出的菜单）
  final GlobalKey _toolbarMenuKey = GlobalKey();

  /// 支持的播放速度档位
  static const List<double> _playbackRates = [0.75, 1, 1.25, 1.5, 2, 3];

  /// 工具栏「单一循环」开关：只循环当前视频，播完不跳下一个。
  ///
  /// 与设置页的「循环播放」（整批文件播完后的行为）是两个独立概念，互不影响。
  bool _singleLoop = false;

  /// 是否启用「接续播放」。从设置缓存下来，避免退出/销毁阶段再访问 Provider。
  bool _resumePlaybackEnabled = true;

  /// 待应用的接续播放位置：等视频时长就绪后再 seek，避免被加载流程覆盖。
  Duration? _pendingResumeSeek;

  /// 播放器事件流订阅
  final List<StreamSubscription<dynamic>> _playerSubs = [];

  /// 切换动画由控制器驱动，避免用 [AnimatedSwitcher] 同时挂载两个 [Video]
  /// （多个 [Video] 共用一个 [VideoController] 会互相抢占视频纹理）。
  late final AnimationController _transitionController;

  /// 换片动画时长（固定 0.3 秒）
  static const Duration _transitionDuration = Duration(milliseconds: 300);

  /// 下一次换片的动画来源与方向（1 = 下一个，-1 = 上一个）。
  /// 由各切换入口在通知播放列表前设置，[_openCurrentVideo] 消费后复位为自动。
  _TransitionTrigger _pendingTransition = _TransitionTrigger.auto;
  int _pendingDirection = 1;

  /// 当前正在播放的换片动画来源与方向，供 build 选择动画形式。
  _TransitionTrigger _activeTransition = _TransitionTrigger.auto;
  int _activeDirection = 1;

  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _showInfo = true;
  Timer? _hideInfoTimer;

  /// 缩放/平移手势进行中。
  ///
  /// 手势期间不弹出工具栏（避免双指缩放时工具栏反复闪现干扰体验），
  /// 改为顺延隐藏计时器：手指一直按着就保持隐藏，松手后才重新计时。
  bool _isGestureActive = false;

  /// 当前按在屏幕上的手指数，用于判断“是否真的完全松手”。
  int _pointerCount = 0;

  /// 本轮交互中第一根手指按下的位置（全局逻辑坐标）。
  ///
  /// 用于在松手时判断这次“轻点”是否落在工具栏的按钮上。
  /// 工具栏内的按钮有自己的 onPressed，若把“点按钮”也当成“轻点画面”，
  /// 就会在按钮回调改完状态后立刻把工具栏隐藏掉（例如点播放/暂停后
  /// 工具栏一闪就消失、自动播放计时器被取消），表现为“按钮点了没反应”。
  Offset? _pointerDownPosition;

  /// 顶部工具栏（AppBar）、底部工具栏（含信息栏、进度条、按钮行）的位置引用，
  /// 用于判断按下的落点是否在工具栏内（见 [_isPointOnToolbar]）。
  final GlobalKey _topControlsKey = GlobalKey();
  final GlobalKey _bottomControlsKey = GlobalKey();

  /// 本轮交互中指尖漂移的最大距离（逻辑像素）。
  ///
  /// 用手势起点到当前焦点的总位移判定“是否发生了拖动”，
  /// 而不是单帧位移——缓慢拖动时每帧位移都小于阈值，
  /// 用单帧判定会被误认为“轻点”。
  double _gestureTravel = 0.0;

  /// 本轮交互是否曾同时出现两根及以上手指（双指捏合）。
  bool _multiPointerUsed = false;

  /// 本次手势是否发生了位移或缩放。
  /// 未发生则视为“轻点”，可在松手时切换工具栏显隐。
  bool _gestureMoved = false;

  /// 判定“轻点 vs 拖动”的位移阈值（逻辑像素）。
  /// 取 kTouchSlop 同量级，与框架对“拖动”的认定保持一致。
  static const double _tapMoveSlop = 18.0;

  // ---- 视频缩放/平移 ----
  /// 最小缩放倍数（1.0 即“适应屏幕”）
  static const double _minScale = 1.0;

  /// 最大缩放倍数
  static const double _maxScale = 5.0;

  /// 判定“已放大”的浮点容差
  static const double _zoomEpsilon = 0.01;

  /// 松手切换阈值：拖到边缘后向外推超过该像素数，松开左键才切到上一个/下一个。
  /// 既避免“刚碰到边缘就被切走”，也避免轻微抖动误触发。
  static const double _edgeSwitchThreshold = 24.0;

  double _scale = 1.0;
  double _rotation = 0.0;
  Offset _position = Offset.zero;
  Offset _startPosition = Offset.zero;
  double _startScale = 1.0;

  // ---- 缩放/平移的绘制状态（只重建 Transform 子树）----
  /// 当前用于绘制的缩放与平移量。
  ///
  /// 拖动时每帧 `setState` 会重建整个播放页（含大量工具栏语义节点），
  /// 在 Windows 无障碍层（UIA）同时做命中测试时容易触发引擎崩溃，也会
  /// 明显拖慢拖动。这里把绘制状态放进独立的 [ValueNotifier]，只让
  /// [Transform] 子树跟随更新，整页布局与语义树保持不变。
  final ValueNotifier<_ViewTransform> _viewTransform = ValueNotifier(
    const _ViewTransform(scale: 1.0, position: Offset.zero),
  );

  /// 手势开始时焦点相对视口中心的位置
  Offset _startFocal = Offset.zero;

  /// 视口尺寸（由 [LayoutBuilder] 的布局结果缓存）。
  /// 在 build 期间只写入这个字段（而非 _viewportCenter），
  /// 视口中心由 [_viewportCenter] 计算得到。
  Size? _viewportSizeCache;

  /// 单指拖拽已放大的视频时，累计的“超出边界”横向溢出量：
  /// 正值=顶在右侧边缘并继续往外推，负值=顶在左侧边缘并继续往外推。
  ///
  /// 拖拽过程中不切换，只有松开左键时才据此判断是否切换上一个/下一个。
  double _edgeOverflow = 0.0;

  /// 本次手势中是否出现过捏合（双指缩放）。
  /// 用于在松手时区分“滑动切换”与“捏合缩放”，避免缩回原尺寸时误切换。
  bool _gesturePinched = false;

  // ---- 单指滑动（未放大时）----
  /// 本轮手势的主轴；只在首次超过阈值时锁定一次，避免中途来回抖动。
  _SwipeAxis _swipeAxis = _SwipeAxis.none;

  /// 纵向滑动累计位移（逻辑像素，上负下正）
  double _swipeDragDy = 0.0;

  /// 横向滑动开始时的播放位置，用于在其基础上叠加拖动偏移。
  Duration _seekStartPosition = Duration.zero;

  /// 锁定主轴的位移阈值（逻辑像素）
  static const double _axisLockSlop = 12.0;

  /// 纵向滑动切换视频的位移阈值（逻辑像素）
  static const double _swipeSwitchThreshold = 60.0;

  /// 纵向滑动切换视频的速度阈值（逻辑像素/秒）
  static const double _swipeSwitchVelocity = 300.0;

  /// 滚轮/键盘缩放的乘法步长（每次 ×[_zoomStep] 或 ÷[_zoomStep]）
  static const double _zoomStep = 1.1;

  /// 本轮交互是否用过右键（右键用于呼出小菜单，不应被当成“轻点画面”切换工具栏）
  bool _secondaryButtonUsed = false;

  /// 当前已打开媒体的路径，用于判断是否需要换片（null 表示尚未打开）
  String? _openPath;

  /// 包裹视频区域的 GestureDetector，用于取得真实视口尺寸
  final GlobalKey _gestureKey = GlobalKey();

  bool _wasPlayingBeforeDelete = false;
  bool _showDeleteMessage = false;
  String _deleteMessageText = '';
  double _autoRotation = 0.0;

  /// 文件大小缓存的加载中标记（防止重复请求）
  final Set<String> _metaLoading = {};

  // ---- 视频元信息缓存（避免在 build 中同步读盘/解码） ----
  /// 缓存的文件大小文本，键为视频路径。
  /// 原先该信息在 build 里同步读盘，触摸显示工具栏时会导致每帧读盘 → 手势掉帧。
  /// 分辨率不再需要缓存：播放器解码后可直接从事件流拿到宽高。
  final Map<String, String> _fileSizeCache = {};

  // 记录最近一次已应用的运行时设置，用于检测设置变更并及时应用
  VideoOrientation _lastOrientation = VideoOrientation.followSystem;
  int _lastControlsHideDelay = -1;
  bool _lastHideToolbar = true;
  bool _lastLoopPlay = false;

  /// 播放器内临时锁定的屏幕方向（移动端手动切换）。
  /// null 表示不临时锁，跟随设置里的 [VideoOrientation]。
  /// 仅使用 [VideoOrientation.portrait] / [VideoOrientation.landscape] 两值。
  /// 退出播放页时会自动清除并还原设置里的方向。
  VideoOrientation? _playerTempOrientation;

  /// 当前视频的原始像素尺寸，用于计算平移边界与自动旋转。
  /// 由播放器事件流（width/height）异步填充。
  Size? get _intrinsicSize {
    final w = _videoWidth;
    final h = _videoHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return Size(w.toDouble(), h.toDouble());
  }

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    _slideProvider = slideProvider;

    // 播放时保持屏幕常亮，避免进入省电模式自动熄屏
    WakelockPlus.enable();

    // 记录进入播放前的全屏状态，供退出播放时决定是保持全屏还是还原窗口
    _wasFullscreenBeforePlayback = FullscreenService.instance.isFullscreen;

    // 创建播放内核：Player 负责解码，VideoController 提供渲染纹理。
    // MediaKit.ensureInitialized() 已在 main 中调用，此处可直接构造。
    //
    // libass 必须显式开启：media_kit 默认 libass=false，会把 mpv 的
    // sub-visibility / sub-ass 设为 no，内嵌字幕（尤其 dvdsub、PGS 等位图
    // 字幕）就完全不显示，切换字幕也看不到效果。
    _player = Player(configuration: const PlayerConfiguration(libass: true));
    _videoController = VideoController(_player);
    _transitionController = AnimationController(
      vsync: this,
      duration: _transitionDuration,
    );
    _volume = _player.state.volume;
    _listenPlayer();

    // 兜底：上一个播放器若因页面未销毁而残留，先销毁它，避免旧视频与
    // 新视频同时出声（表现为「点开其他视频也打断不了原来的播放」）。
    final previousPlayer = _activePlayer;
    _activePlayer = _player;
    if (previousPlayer != null) {
      unawaited(_disposePlayerQuietly(previousPlayer));
    }

    // 初始化最近一次设置快照，避免首帧误判为设置变更
    _lastOrientation = settings.videoOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastLoopPlay = settings.loopPlay;

    // 注册全局键盘监听器，不依赖 FocusNode
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);

    // 播放列表变化（换片 / 播放/暂停意图变化）时同步播放器
    slideProvider.addListener(_onSlideChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // 如果设置了自动全屏，先进入全屏再开始播放。
      // 手机端应用本身就是独占全屏的，不存在窗口化的「全屏」概念，
      // 因此该设置只对桌面端生效（设置页在手机端也不展示这一项）。
      final startFullscreen =
          settings.startFullscreen && !Platform.isAndroid && !Platform.isIOS;
      if (startFullscreen) {
        // 延迟更长时间再进入全屏，确保窗口完全就绪
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          _enterFullscreen();
        });
      }

      // 打开当前视频（播放状态由 SlideProvider 的播放意图决定）
      _openCurrentVideo();

      // 应用屏幕方向设置
      _applyScreenOrientation(settings);

      // 在播放状态确定后再设置自动隐藏
      _hideControlsDelayed();
      _hideInfoDelayed();

      // 远端视频：确认共享终端当前开放的操作权限，决定工具栏按钮
      final current = slideProvider.videos.isEmpty
          ? null
          : slideProvider.videos[slideProvider.currentIndex];
      if (current != null && current.isRemote) {
        final device = _deviceForRemoteItem(current);
        if (device != null) {
          unawaited(
            Provider.of<LanProvider>(
              context,
              listen: false,
            ).refreshCapabilities(device),
          );
        }
      }
    });
  }

  /// 订阅播放器事件流，把原生播放状态映射到本页面的状态快照。
  void _listenPlayer() {
    final stream = _player.stream;
    _playerSubs
      ..add(stream.playing.listen(_onPlayingChanged))
      ..add(
        stream.buffering.listen((value) {
          if (mounted) setState(() => _buffering = value);
        }),
      )
      ..add(stream.completed.listen(_onCompletedChanged))
      ..add(
        stream.position.listen((value) {
          if (mounted) setState(() => _videoPosition = value);
          // 位置事件里顺手记录进度（内部做去重与合并写入）
          _persistCurrentProgress();
        }),
      )
      ..add(
        stream.duration.listen((value) {
          if (mounted) setState(() => _videoDuration = value);
          _maybeApplyResumeSeek();
        }),
      )
      ..add(
        stream.volume.listen((value) {
          if (mounted) setState(() => _volume = value);
        }),
      )
      ..add(stream.width.listen((value) => _onVideoSizeChanged(value, null)))
      ..add(stream.height.listen((value) => _onVideoSizeChanged(null, value)))
      ..add(
        stream.error.listen((value) {
          if (mounted) setState(() => _playbackError = value);
        }),
      )
      // 轨道可用列表：视频加载后一次性给出所有音轨/字幕
      ..add(
        stream.tracks.listen((value) {
          if (!mounted) return;
          setState(() => _tracks = value);
          _contextMenuEntry?.markNeedsBuild();
          // 应用用户对该视频记忆的音轨/字幕偏好；
          // 偏好的轨道若已不存在于新 tracks 里则静默跳过
          final key = _openPath;
          if (key != null) {
            TrackPrefService.instance.applyPrefsIfMatched(
              videoKey: key,
              tracks: value,
              player: _player,
            );
          }
        }),
      )
      // 当前选中轨道：用户或系统切换音轨/字幕时更新
      ..add(
        stream.track.listen((value) {
          if (!mounted) return;
          setState(() => _currentTrack = value);
          _contextMenuEntry?.markNeedsBuild();
          // 保存用户对该视频的音轨/字幕偏好（auto/no 会被自动过滤掉）
          final key = _openPath;
          if (key != null) {
            unawaited(
              TrackPrefService.instance.save(
                key,
                audioId: value.audio.id,
                subtitleId: value.subtitle.id,
              ),
            );
          }
        }),
      );
  }

  void _onPlayingChanged(bool playing) {
    if (!mounted) return;
    setState(() => _playing = playing);
  }

  /// 播放结束事件：循环播放由播放器自身完成；否则自动连播下一个视频。
  void _onCompletedChanged(bool completed) {
    if (!mounted) return;
    if (!completed) {
      if (_completed) setState(() => _completed = false);
      return;
    }
    // 播放完毕：清除该视频的进度，下次从头开始
    final finishedKey = _openPath;
    if (finishedKey != null) PlaybackProgressService.instance.clear(finishedKey);

    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // 单一循环：交给播放器自己重播当前视频，不进入下一个
    if (_singleLoop) return;

    setState(() => _completed = true);

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 从瀑布流进入时按列表既有顺序（即其当前排序）播放，忽略设置页的随机模式
    final followListOrder = slideProvider.followListOrder;
    final isRandom = !followListOrder && settings.playOrder == PlayOrder.random;
    // 是否已播到本批次的最后一个。
    // 随机模式是「洗牌后的固定顺序」，末尾即随机序列的最后一个元素。
    final atBatchEnd = isRandom
        ? slideProvider.isRandomPlaybackComplete()
        : slideProvider.currentIndex >= slideProvider.videos.length - 1;

    // 「循环播放」关闭：播完本批最后一个就停止播放并退回进入播放前的页面
    if (!settings.loopPlay) {
      if (atBatchEnd) {
        _exitPlayback();
        return;
      }
      _nextVideo(trigger: _TransitionTrigger.auto);
      return;
    }

    // 「循环播放」开启：随机模式一轮走完后重新洗牌，再从新顺序的第一个继续
    if (isRandom && atBatchEnd) {
      // 重新洗牌开始下一轮；若新顺序的第一个仍是刚播完的那个视频，交换到别处
      slideProvider.reshuffleForNextRound();
      slideProvider.goToStartPosition(PlayOrder.random);
      return;
    }

    // 其余情况推进到下一个（顺序/逆序到末尾时由列表取模回到第一个）
    _nextVideo(trigger: _TransitionTrigger.auto);
  }

  /// 播放器解码出视频尺寸后，重算自动旋转与平移边界。
  void _onVideoSizeChanged(int? width, int? height) {
    if (!mounted) return;
    final newWidth = width ?? _videoWidth;
    final newHeight = height ?? _videoHeight;
    if (newWidth == _videoWidth && newHeight == _videoHeight) return;

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    setState(() {
      _videoWidth = newWidth;
      _videoHeight = newHeight;
      _autoRotation = _computeAutoRotation(slideProvider, settings);
      _position = _clampCurrent(settings);
    });
    _publishTransform();
  }

  /// 播放列表变化时的处理：换片则重新打开，否则只同步播放/暂停。
  void _onSlideChanged() {
    if (!mounted) return;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (slideProvider.videos.isEmpty) return;
    final key = slideProvider.videos[slideProvider.currentIndex].key;
    if (key != _openPath) {
      _openCurrentVideo();
    } else {
      // 没有真正换片时清掉待用的动画设置，避免下一次换片误用旧来源
      _pendingTransition = _TransitionTrigger.auto;
      _pendingDirection = 1;
      _syncPlayState();
    }
  }

  /// 打开当前索引对应的视频。
  void _openCurrentVideo() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (slideProvider.videos.isEmpty) return;

    final index = slideProvider.currentIndex;
    final video = slideProvider.videos[index];
    if (video.key == _openPath) return;

    // 换片前先把上一个视频的进度落盘，再重置页面状态
    _persistCurrentProgress(flushNow: true);

    _openPath = video.key;
    _pendingResumeSeek = null;

    // 消费本次切换的动画来源与方向，随后复位为自动（删除等其它路径触发换片时用淡入）
    _activeTransition = _pendingTransition;
    _activeDirection = _pendingDirection;
    _pendingTransition = _TransitionTrigger.auto;
    _pendingDirection = 1;

    setState(() {
      _completed = false;
      _buffering = false;
      _playbackError = null;
      _videoPosition = Duration.zero;
      _videoDuration = Duration.zero;
      _videoWidth = null;
      _videoHeight = null;
      _seekPreview = null;
      _autoRotation = 0.0;
      // 换片后回到「适应屏幕」，避免新视频带着上一个的缩放/位移
      _scale = _minScale;
      _rotation = 0.0;
      _position = Offset.zero;
      _edgeOverflow = 0.0;
    });
    // 换片时缩放/平移归零，立即同步到绘制状态
    _publishTransform();

    _applyPlaylistMode();
    // 接续播放：打开后跳回上次位置；从头播放时忽略历史进度
    final resumeAt = settings.resumePlayback == ResumePlayback.resume
        ? PlaybackProgressService.instance.positionFor(video.key)
        : null;
    // 本机文件用路径、共享视频用 HTTP 地址，media_kit 会自动识别协议
    unawaited(
      _player
          .open(Media(video.playbackUrl), play: slideProvider.isPlaying)
          .then((_) {
            if (!mounted || _openPath != video.key) return;
            // 换片后保持当前倍速（个别播放内核会在打开新文件时重置速度）
            if (_playbackRate != 1.0) {
              unawaited(_player.setRate(_playbackRate).catchError((_) {}));
            }
            // 时长未就绪时 seek 会被加载流程覆盖，先挂起、等 duration 事件再跳转
            _pendingResumeSeek = resumeAt;
            _maybeApplyResumeSeek();
          })
          .catchError((_) {}),
    );

    _transitionController.forward(from: 0);

    // 恢复该视频上次手动锁定的方向；没手动切过则跟随设置
    _playerTempOrientation = switch (TrackPrefService.instance
        .orientationFor(video.key)) {
      'landscape' => VideoOrientation.landscape,
      'portrait' => VideoOrientation.portrait,
      _ => null,
    };
    _applyScreenOrientation(settings);
  }

  /// 按工具栏的「单一循环」设置播放器自身的循环模式。
  void _applyPlaylistMode() {
    // 只由工具栏的「单一循环」决定播放器自身的循环模式：
    // 设置页的「循环播放」管的是「一批文件播完之后」的行为，由 _onCompletedChanged
    // 在应用层处理（本应用在 media_kit 侧始终只有当前这一个 Media）。
    _player.setPlaylistMode(
      _singleLoop ? PlaylistMode.single : PlaylistMode.none,
    );
  }

  /// 让实际播放状态与 [SlideProvider] 的播放意图保持一致。
  void _syncPlayState() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (slideProvider.isPlaying && !_playing && !_completed) {
      _player.play();
    } else if (!slideProvider.isPlaying && _playing) {
      _player.pause();
    }
  }

  @override
  void dispose() {
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    _playerSubs.clear();
    _slideProvider.removeListener(_onSlideChanged);
    // 退出播放页时复位播放意图，避免回到列表后仍残留「播放中」状态
    _slideProvider.stopPlay();

    // 若右键菜单还开着（例如退出播放时未点击），一并关闭，避免回调指向已销毁的 State
    _closeContextMenu();

    _hideControlsTimer?.cancel();
    _hideInfoTimer?.cancel();
    _viewTransform.dispose();

    _transitionController.dispose();

    if (identical(_activePlayer, _player)) {
      _activePlayer = null;
    }

    // 显式先停一次：Player.dispose 内部的停止动作排在若干异步初始化等待之后，
    // 页面销毁期间这些等待不保证及时返回，会让原生播放一直在后台继续。
    unawaited(_player.stop().catchError((_) {}));
    unawaited(_player.dispose().catchError((_) {}));

    // 移除全局键盘监听器
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);

    // 释放屏幕常亮，恢复系统正常熄屏行为
    WakelockPlus.disable();

    // 还原进入播放前的全屏状态，但不调用 setState
    _restoreFullscreenBeforePlayback();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 清理移动端临时方向覆盖，解锁所有方向（回到系统默认行为）
    _playerTempOrientation = null;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /// 检测设置变更并将运行时效果（屏幕方向、自动隐藏、循环模式等）即时应用。
  /// 由于 build 中不能调用 setState，将真正应用动作延迟到本次 build 完成后执行。
  void _applySettingsToPlayback(SettingsProvider settings) {
    _resumePlaybackEnabled = settings.resumePlayback == ResumePlayback.resume;
    final orientationChanged = settings.videoOrientation != _lastOrientation;
    final controlsChanged =
        settings.controlsHideDelay != _lastControlsHideDelay ||
        settings.hideToolbar != _lastHideToolbar;
    final loopChanged = settings.loopPlay != _lastLoopPlay;

    _lastOrientation = settings.videoOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastLoopPlay = settings.loopPlay;

    if (!orientationChanged && !controlsChanged && !loopChanged) {
      return;
    }

    // 延迟到 build 完成后应用，避免 build 中调用 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (orientationChanged) {
        _applyScreenOrientation(settings);
        final slideProvider = Provider.of<SlideProvider>(
          context,
          listen: false,
        );
        setState(() {
          _autoRotation = _computeAutoRotation(slideProvider, settings);
          _position = _clampCurrent(settings);
        });
        _publishTransform();
      }
      if (controlsChanged) {
        // 信息条的自动隐藏与工具栏同源，一起重排计时
        _hideControlsDelayed();
        _hideInfoDelayed();
      }
      if (loopChanged) {
        _applyPlaylistMode();
      }
    });
  }

  /// 暂停播放
  void _pausePlayback() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 保存当前播放状态
    _wasPlayingBeforeDelete = slideProvider.isPlaying;
    if (slideProvider.isPlaying) {
      slideProvider.stopPlay();
    }
  }

  /// 恢复播放
  void _resumePlayback() {
    // 只有在暂停前是播放状态时才恢复播放
    if (!_wasPlayingBeforeDelete) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (!slideProvider.isPlaying && slideProvider.videos.isNotEmpty) {
      slideProvider.startPlay();
    }
  }

  /// 处理删除操作
  /// 删除当前视频。
  /// [invertAction] 为 true 时执行与“删除行为”设置相反的动作（对应 Ctrl+Del）。
  void _showDeleteConfirmation({bool invertAction = false}) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final action = _effectiveDeleteAction(settings, invertAction);

    // 如果是排除播放，直接执行操作，不需要确认，也不需要退出全屏
    if (action == DeleteAction.exclude) {
      _deleteCurrentVideo(action);
      return;
    }

    // 如果是实际删除，暂停播放后显示确认对话框
    _pausePlayback();
    _showDeleteConfirmationDialog(action);
  }

  /// 计算本次实际使用的删除行为：[invert] 为 true 时取与设置相反的一项。
  DeleteAction _effectiveDeleteAction(SettingsProvider settings, bool invert) {
    if (!invert) return settings.deleteAction;
    return settings.deleteAction == DeleteAction.exclude
        ? DeleteAction.delete
        : DeleteAction.exclude;
  }

  /// 实际显示删除确认对话框
  void _showDeleteConfirmationDialog(DeleteAction action) {
    if (!mounted) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    final currentVideo = slideProvider.videos[slideProvider.currentIndex];
    final deleteActionText = action == DeleteAction.exclude
        ? AppLocalizations.of(context).excludeFromPlay
        : AppLocalizations.of(context).deleteFromDisk;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          action == DeleteAction.exclude
              ? AppLocalizations.of(context).confirmExclude
              : AppLocalizations.of(context).confirmDelete,
        ),
        content: Text(
          '${AppLocalizations.of(context).confirmDeleteMsg(deleteActionText)}\n\n${currentVideo.name}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resumePlayback();
            },
            child: Text(AppLocalizations.of(context).cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final videosRemain = await _deleteCurrentVideo(action);
              if (videosRemain) {
                _resumePlayback();
              }
            },
            child: Text(
              AppLocalizations.of(context).confirm,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示删除通知（自定义覆盖层，在全屏模式下也能显示）
  void _showDeleteNotification(String message) {
    setState(() {
      _deleteMessageText = message;
      _showDeleteMessage = true;
    });

    // 2秒后自动隐藏
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showDeleteMessage = false;
        });
      }
    });
  }

  /// 由远端视频的播放地址还原设备信息（用于排除/复制等远程操作）
  LanDevice? _deviceForRemoteItem(VideoItem item) {
    final uri = Uri.tryParse(item.remoteUrl ?? '');
    if (uri == null) return null;
    return LanDevice(
      id: item.deviceId ?? '',
      name: uri.host,
      host: uri.host,
      port: uri.port,
      folderCount: 0,
      lastSeen: DateTime.now(),
    );
  }

  /// 复制当前远端视频到本机
  Future<void> _copyCurrentVideo() async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (slideProvider.videos.isEmpty) return;
    final item = slideProvider.videos[slideProvider.currentIndex];
    if (!item.isRemote) return;

    final loc = AppLocalizations.of(context);
    if (RemoteCopyService.isCopying) {
      _showDeleteNotification(loc.lanCopyBusy);
      return;
    }

    final destination = await RemoteCopyService.resolveDestination(context);
    if (!mounted || destination == null) return;

    final status = await RemoteCopyService.copyToLocal(
      context,
      item,
      destination,
    );
    if (!mounted) return;
    switch (status) {
      case RemoteCopyStatus.success:
        _showDeleteNotification(loc.lanCopied);
        break;
      case RemoteCopyStatus.cancelled:
        _showDeleteNotification(loc.lanCopyCancelled);
        break;
      case RemoteCopyStatus.busy:
        _showDeleteNotification(loc.lanCopyBusy);
        break;
      case RemoteCopyStatus.failed:
        _showDeleteNotification(loc.lanCopyFailed);
        break;
    }
  }

  /// 删除当前视频（[action] 为本次实际使用的删除行为）
  /// 返回 true 表示视频列表不为空，false 表示视频列表为空且已返回主界面
  Future<bool> _deleteCurrentVideo(DeleteAction action) async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final currentIndex = slideProvider.currentIndex;
    final currentVideo = slideProvider.videos[currentIndex];

    // 共享视频：只能请求共享主机「排除播放」，不能在本机删除或排除
    if (currentVideo.isRemote) {
      final loc = AppLocalizations.of(context);
      if (action != DeleteAction.exclude) {
        if (mounted) _showDeleteNotification(loc.lanRemoteUnsupported);
        return false;
      }
      final remoteId = currentVideo.remoteId ?? '';
      final sep = remoteId.indexOf('/');
      final device = _deviceForRemoteItem(currentVideo);
      if (sep <= 0 || device == null) {
        if (mounted) _showDeleteNotification(loc.lanRemoteExcludeFailed);
        return false;
      }
      final lan = Provider.of<LanProvider>(context, listen: false);
      var capabilities = lan.capabilitiesFor(device.id);
      if (!capabilities.exclude) {
        capabilities = await lan.refreshCapabilities(device);
      }
      if (!capabilities.exclude) {
        if (mounted) _showDeleteNotification(loc.lanRemotePermissionDenied);
        return false;
      }

      final ok = await LanClientService.instance.excludeVideo(
        device,
        folderId: remoteId.substring(0, sep),
        id: remoteId.substring(sep + 1),
      );
      if (!ok) {
        if (mounted) _showDeleteNotification(loc.lanRemoteExcludeFailed);
        return false;
      }

      // 通知远端瀑布流：返回时立即隐藏该条目，避免整页重载
      lan.markRemoteExcluded(device.id, remoteId);

      slideProvider.removeVideo(currentIndex);
      if (slideProvider.videos.isEmpty) {
        // 列表清空后直接返回：先停播放，避免返回过程中原视频还在出声
        _stopPlaybackForExit();
        if (mounted) Navigator.pop(context);
        return false;
      }
      if (mounted) _showDeleteNotification(loc.excluded);
      return true;
    }

    if (action == DeleteAction.delete) {
      // 实际删除文件
      try {
        await File(currentVideo.path).delete();
      } catch (e) {
        // 文件删除失败，可能是文件被占用（使用自定义覆盖层，在全屏模式下也能显示）
        if (mounted) {
          _showDeleteNotification(AppLocalizations.of(context).deleteFailed);
        }
        return true;
      }
    } else if (action == DeleteAction.exclude) {
      // 排除播放：记录到已排除列表，供"选择文件夹"页面的"已排除的文件"使用
      settings.addExcludedPath(currentVideo.path);
    }

    // 从播放列表中移除
    slideProvider.removeVideo(currentIndex);

    // 如果视频列表为空，返回主界面
    if (slideProvider.videos.isEmpty) {
      // 先停播放，避免返回过程中原视频还在出声
      _stopPlaybackForExit();
      if (mounted) {
        Navigator.pop(context);
      }
      return false;
    } else {
      // 显示删除成功提示（使用自定义覆盖层，在全屏模式下也能显示）
      if (mounted) {
        _showDeleteNotification(
          action == DeleteAction.exclude
              ? AppLocalizations.of(context).excluded
              : AppLocalizations.of(context).deleted,
        );
      }
      return true;
    }
  }

  /// 切换到下一个视频。
  ///
  /// [trigger] 决定换片动画：滚轮/手势等手动切换用上下滑动，
  /// 工具栏按钮与方向键用左右滑动，播放结束自动切换用淡入淡出。
  void _nextVideo({_TransitionTrigger trigger = _TransitionTrigger.vertical}) {
    _pendingTransition = trigger;
    _pendingDirection = 1;
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // 切换后回到「适应屏幕」状态，避免新视频带着上一个的缩放/位移
    _resetZoom();

    // 跟随瀑布流顺序时，队列已经是用户看到的顺序，直接按索引推进
    if (!slideProvider.followListOrder &&
        settings.playOrder == PlayOrder.random) {
      // 使用预打乱的随机序列进行播放
      slideProvider.nextRandomVideo();
    } else {
      // 顺序/最新优先/最旧优先统一使用顺序索引播放
      slideProvider.nextVideo();
    }
  }

  /// 切换到上一个视频（动画规则同 [_nextVideo]）。
  void _prevVideo({_TransitionTrigger trigger = _TransitionTrigger.vertical}) {
    _pendingTransition = trigger;
    _pendingDirection = -1;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 切换后回到「适应屏幕」状态，避免新视频带着上一个的缩放/位移
    _resetZoom();

    slideProvider.prevVideo(
      playOrder: slideProvider.followListOrder ? null : settings.playOrder,
    );
  }

  void _hideControlsDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    _hideControlsTimer?.cancel();

    // 如果关闭了隐藏工具栏选项，始终保持显示
    if (!settings.hideToolbar) {
      if (!_showControls) {
        setState(() {
          _showControls = true;
        });
      }
      return;
    }

    // 根据设置的延迟时间自动隐藏
    _hideControlsTimer = Timer(
      Duration(seconds: settings.controlsHideDelay),
      _hideControlsIfIdle,
    );
  }

  /// 信息条的自动隐藏与工具栏统一控制：跟随「自动隐藏工具栏」开关与「隐藏延迟」。
  void _hideInfoDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _hideInfoTimer?.cancel();
    if (settings.hideToolbar) {
      _hideInfoTimer = Timer(
        Duration(seconds: settings.controlsHideDelay),
        _hideInfoIfIdle,
      );
    }
  }

  /// 同 [_hideControlsIfIdle]：手势进行中不隐藏信息栏，
  /// 避免长按拖动时触发额外重建。
  void _hideInfoIfIdle() {
    if (!mounted || _isGestureActive || _pointerCount > 0) return;
    setState(() {
      _showInfo = false;
    });
  }

  /// 手指抬起：全部松开时结束手势状态。
  ///
  /// 若本次只是“轻点”（没有位移、没有捏合、也没触发切换），
  /// 就切换工具栏显隐——相当于把点击的切换逻辑
  /// 推迟到松手时，缩放时便不会弹出工具栏。
  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerCount > 0) _pointerCount--;
    if (_pointerCount > 0) return;
    _pointerCount = 0;
    _onAllPointersReleased();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointerCount > 0) _pointerCount--;
    if (_pointerCount > 0) return;
    _pointerCount = 0;
    _onAllPointersReleased();
  }

  /// 判断某个全局坐标点是否落在工具栏（顶部 AppBar / 底部按钮行）内。
  ///
  /// 用几何判定代替“在按钮之外再套一层 Listener 置标志位”：后者依赖
  /// 控件树中“按下/抬起”事件的先后顺序，一旦顺序变化就会失效；
  /// 而 [GlobalKey] + 命中矩形只取决于布局结果，与事件顺序无关。
  bool _isPointOnToolbar(Offset globalPosition) {
    for (final key in [_topControlsKey, _bottomControlsKey]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(
        globalPosition,
      )) {
        return true;
      }
    }
    return false;
  }

  void _onAllPointersReleased() {
    _isGestureActive = false;
    // 取出本轮按下的落点后立即清空，避免影响下一次交互
    final downPosition = _pointerDownPosition;
    _pointerDownPosition = null;
    // 仅“单指轻点”才切换工具栏：
    // 双指捏合、有位移的拖动（含放大后的平移/松手切换）都不会走到这里切换工具栏。
    // 右键用于呼出小菜单，同样不能当成“轻点画面”。
    final isSingleTap =
        !_gestureMoved &&
        !_gesturePinched &&
        !_multiPointerUsed &&
        !_secondaryButtonUsed;
    if (isSingleTap) {
      // 落在工具栏上的轻点属于“点按钮”，交给按钮自己的 onPressed 处理：
      // 只顺延自动隐藏计时，既不隐藏工具栏，也不取消自动播放计时器。
      // 注意不能用 _showControlsTemporarily()：那会把 _showInfo 也置为 true，
      // 让“点按钮”意外带出视频信息栏。
      if (downPosition != null && _isPointOnToolbar(downPosition)) {
        _hideControlsDelayed();
        _hideInfoDelayed();
        return;
      }
      // 轻点画面 → 切换工具栏显隐（显示中则立即关闭，已关闭则显示）
      _toggleControls();
    } else {
      // 缩放/拖动结束 → 重新开始自动隐藏计时
      _hideControlsDelayed();
      _hideInfoDelayed();
    }
  }

  /// 手势进行中把自动隐藏计时器顺延，而不是立刻弹出工具栏。
  ///
  /// 否则用户每次双指缩放都会让工具栏/信息栏闪现，
  /// 并且缩放手势本身会因多出来的重建而变得不流畅。
  /// 隐藏动作受 [_hideControlsIfIdle] 保护，手指按住期间不会生效。
  void _deferControlHide() {
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 最近一次因鼠标悬停移动而重置自动隐藏计时的时间，用于节流。
  DateTime _lastHoverReset = DateTime.fromMillisecondsSinceEpoch(0);

  /// 鼠标移动（未按键的悬停移动）算作一次“操作”，顺延工具栏自动隐藏计时。
  ///
  /// 桌面端用户常把鼠标停在控制区上操作，若移动鼠标不重置计时，工具栏会在
  /// 操作途中被自动隐藏。仅在工具栏当前可见时顺延；已隐藏时移动鼠标不应把
  /// 它重新唤出。悬停事件按像素高频触发，这里做 200ms 节流避免频繁重建计时器。
  void _onPointerHoverActivity() {
    if (!_showControls) return;
    final now = DateTime.now();
    if (now.difference(_lastHoverReset).inMilliseconds < 200) return;
    _lastHoverReset = now;
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 只在手势确实已经结束（没有任何指针按下）时才隐藏工具栏。
  ///
  /// 放大画面时用户可能连续多次捏合/拖动，中途松手又立刻按下，
  /// 这里必须避免在两次手势之间把工具栏隐藏掉再弹回来。
  void _hideControlsIfIdle() {
    if (!mounted || _isGestureActive || _pointerCount > 0) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (settings.keepControlsOnPause && !slideProvider.isPlaying) return;
    setState(() {
      _showControls = false;
    });
  }

  /// 显示工具栏与信息栏，并在超时后自动隐藏。
  ///
  /// 仅由真正的“点击”触发；按下瞬间不再弹出，避免缩放时工具栏闪现。
  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() {
      _showControls = true;
      _showInfo = true;
    });
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 轻点屏幕切换工具栏显隐。
  ///
  /// · 正在显示 → 立即关闭（无需等超时），同时取消待触发的隐藏计时器；
  /// · 已关闭   → 立刻显示并重新开始自动隐藏计时。
  ///
  /// 若用户在设置里关闭了“自动隐藏工具栏”，则工具栏应保持常显，
  /// 此时轻点不再关闭它（避免出现“关不掉又没超时可恢复”的困惑）。
  void _toggleControls() {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (_showControls && settings.hideToolbar) {
      _hideControlsTimer?.cancel();
      _hideInfoTimer?.cancel();
      setState(() {
        _showControls = false;
        _showInfo = false;
      });
      return;
    }
    _showControlsTemporarily();
  }

  void _togglePlay() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 播放已结束：点击播放表示从头重播
    if (_completed) {
      setState(() => _completed = false);
      unawaited(_player.seek(Duration.zero));
      if (slideProvider.isPlaying) {
        unawaited(_player.play());
      } else {
        slideProvider.startPlay();
      }
      _hideControlsDelayed();
      return;
    }

    if (slideProvider.isPlaying) {
      slideProvider.stopPlay();
    } else {
      slideProvider.startPlay();
    }
    // 播放/暂停由播放列表监听统一同步，这里只处理工具栏的自动隐藏
    _hideControlsDelayed();
  }

  /// 全屏状态由 [FullscreenService] 统一维护（播放页与瀑布流浏览页共用）
  bool get _isFullscreen => FullscreenService.instance.isFullscreen;

  void _enterFullscreen() {
    // Windows 平台由 FullscreenService 实现真正的独占全屏
    setState(() {
      FullscreenService.instance.enter();
    });
  }

  void _exitFullscreen() {
    // Windows 平台由 FullscreenService 恢复窗口
    FullscreenService.instance.exit();
    // 更新全屏状态
    setState(() {
      _showControls = true;
    });
    // 重启自动隐藏定时器
    _hideControlsDelayed();
    _hideInfoDelayed();
  }

  /// 退出播放时还原「进入播放前」的全屏状态。
  ///
  /// - 进入前已是全屏（例如在瀑布流里按过 F11）：保持全屏，不能还原窗口，
  ///   否则会把上一页的全屏状态一并吃掉；
  /// - 进入前是窗口：还原到进入播放前的窗口尺寸与位置。
  ///
  /// 页面销毁与工具栏返回按钮都走这里，避免两处逻辑分叉。
  void _restoreFullscreenBeforePlayback() {
    if (_wasFullscreenBeforePlayback) {
      // 进入前就是全屏：若播放过程中被退出过，这里补回全屏
      if (!FullscreenService.instance.isFullscreen) {
        FullscreenService.instance.enter();
      }
      return;
    }
    FullscreenService.instance.exit();
  }

  // ==================== 缩放与平移 ====================

  /// 视口尺寸（由 [LayoutBuilder] 的实际布局尺寸得到）
  Size get _viewportSize {
    final cached = _viewportSizeCache;
    if (cached != null && !cached.isEmpty) return cached;
    final box = _gestureKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return MediaQuery.sizeOf(context);
  }

  /// 视口中心（原点），手势焦点相对它换算，实现以指尖为锚点的缩放
  Offset get _viewportCenter => _viewportSize.center(Offset.zero);

  /// 当前是否处于放大状态
  bool get _isZoomed => _scale > 1.0 + _zoomEpsilon;

  /// 手动旋转 + 方向自动旋转后的总旋转角（弧度）。
  double get _totalRotation => _rotation + _autoRotation;

  /// 旋转圈数（0~3），供 [RotatedBox] 在布局阶段旋转使用。
  ///
  /// 手动旋转会不断累加 `math.pi / 2`，浮点误差随次数增加；
  /// 统一归一化成整数圈数交给 [RotatedBox]，从根上避免累积误差。
  int get _quarterTurns => normalizeQuarterTurns(_totalRotation);

  /// 视频在屏幕上显示的实际尺寸（未缩放）。
  ///
  /// 视频用 `Transform(scale:)` 缩放，所以这里的返回值是“缩放前”的尺寸；
  /// 平移边界在 [_clamp] 里再乘以 [_scale]。
  ///
  /// 注意：旋转由 [RotatedBox] 在**布局阶段**完成，因此这里必须用
  /// [layoutRotatedFitSize] 复刻「先翻转约束、再适配、再交换回来」的过程。
  /// 若仍按「未旋转视口下适配后再交换」计算，旋转 90° 后的平移边界
  /// 会与实际渲染不符（表现为 contain 下短边留黑边）。
  Size _displayBaseSize(SettingsProvider settings) {
    final viewport = _viewportSize;
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return viewport;

    return layoutRotatedFitSize(
      intrinsic: intrinsic,
      viewport: viewport,
      fit: settings.boxFit,
      quarterTurns: _quarterTurns,
    );
  }

  /// 某轴上的最大平移距离（0 表示该轴已铺满、无需平移）
  double _maxPanFor(double baseAxis, double viewportAxis, double scale) {
    final scaled = baseAxis * scale;
    if (scaled <= viewportAxis) return 0.0;
    return (scaled - viewportAxis) / 2;
  }

  /// 把平移量限制在视频边界内
  ///
  /// [scale] 显式传入，避免与即将写入的 _scale 不同步。
  Offset _clamp(Offset raw, SettingsProvider settings, double scale) {
    final viewport = _viewportSize;
    final base = _displayBaseSize(settings);
    final maxX = _maxPanFor(base.width, viewport.width, scale);
    final maxY = _maxPanFor(base.height, viewport.height, scale);
    return Offset(raw.dx.clamp(-maxX, maxX), raw.dy.clamp(-maxY, maxY));
  }

  /// 用当前缩放值夹紧平移量（供旋转、尺寸变化、手势结束等场景复用）
  Offset _clampCurrent(SettingsProvider settings) =>
      _clamp(_position, settings, _scale);

  /// 把当前 [_scale] / [_position] 同步到绘制状态。
  ///
  /// 只触发 [Transform] 子树重建，不重建整页布局与语义树；
  /// 不需要节流，拖动时的跟手性完全保留。
  void _publishTransform() {
    _viewTransform.value = _ViewTransform(scale: _scale, position: _position);
  }

  /// 以 [localPosition]（相对视口的局部坐标）为锚点做乘法缩放。
  ///
  /// 锚点下的像素在缩放前后保持不动：若缩放倍率由 s0 变为 s1，
  /// 屏幕点满足 `screen = center + P + s * (p - center)`，
  /// 令锚点对应的 screen 不变即可解得 `P1 = P0 + (1 - s1/s0) * (focal - P0)`。
  void _zoomAt(Offset localPosition, double factor) {
    if (!factor.isFinite || factor <= 0 || factor == 1.0) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final newScale = (_scale * factor).clamp(_minScale, _maxScale);
    if ((newScale - _scale).abs() < 1e-6) return;

    final focal = localPosition - _viewportCenter;
    final ratio = newScale / _scale;
    final adjusted = _position + (focal - _position) * (1 - ratio);
    final zoomed = newScale > _minScale + _zoomEpsilon;

    _scale = newScale;
    // 缩回原尺寸时平移量必须归零，否则整个画面会偏离视口中心
    _position = zoomed ? _clamp(adjusted, settings, newScale) : Offset.zero;
    _publishTransform();
  }

  /// 恢复到“适应屏幕”（缩放 1.0、位置归零）。
  void _resetZoom() {
    if (_scale <= _minScale + _zoomEpsilon && _position == Offset.zero) {
      return;
    }
    _scale = _minScale;
    _position = Offset.zero;
    _edgeOverflow = 0.0;
    _publishTransform();
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startPosition = _position;
    _startFocal = details.localFocalPoint - _viewportCenter;
    _gestureTravel = 0.0;

    // 手势开始：标记进行中（挂起工具栏弹出），并重置停靠推进状态。
    // 注意：这里不重置 _gestureMoved/_gesturePinched ——
    // 框架在“双指→单指”时会通过 _reconfigure 重新派发 onStart，
    // 若在此重置会把已经发生的捏合“洗白”成轻点，导致松手时误弹工具栏。
    _isGestureActive = true;
    // 手指按住期间顺延自动隐藏计时，避免手势刚开始就被计时器弹出工具栏
    _deferControlHide();

    // 每次手势开始都重置边缘溢出量与滑动状态：
    // 边缘溢出只在“单指·已放大”的拖拽过程中重新累积，
    // 滑动主轴只在本次手势内确定一次。
    _edgeOverflow = 0.0;
    _gesturePinched = false;
    _swipeAxis = _SwipeAxis.none;
    _swipeDragDy = 0.0;
    _seekStartPosition = _videoPosition;
    // 手势开始时基于当前缩放重新夹紧，保证起点合法
    _position = _clampCurrent(
      Provider.of<SettingsProvider>(context, listen: false),
    );
    _publishTransform();
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    // 位移或缩放超过噪声阈值即视为“真实的缩放/拖动”，而非点击
    _gestureTravel = math.max(
      _gestureTravel,
      (details.localFocalPoint - _viewportCenter - _startFocal).distance,
    );
    if (_gestureTravel > _tapMoveSlop || (details.scale - 1.0).abs() >= 0.02) {
      _gestureMoved = true;
    }

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 换算成以视口中心为原点的坐标，缩放锚点计算会更直观
    final focal = details.localFocalPoint - _viewportCenter;
    final drag = focal - _startFocal;

    // 记录本次手势是否真的做过捏合，供松手时区分滑动与缩放
    if ((details.scale - 1.0).abs() >= 0.02) _gesturePinched = true;

    // ---- 已放大 / 捏合 / 多指：保持原有的缩放 + 平移逻辑 ----
    if (_gesturePinched || _isZoomed || details.pointerCount > 1) {
      // 1) 缩放：以手势焦点为锚点，使焦点下的像素在缩放前后保持不动
      final newScale = (_startScale * details.scale).clamp(
        _minScale,
        _maxScale,
      );
      final ratio = _startScale == 0 ? 1.0 : newScale / _startScale;

      // 2) 平移：
      //    - 缩放带来的分量用 ratio 推导（锚点=焦点）
      //    - 指尖自身的位移（focal - _startFocal）直接叠加，
      //      这样单指拖动时 details.scale 恒为 1.0、ratio 为 1，
      //      平移量恰好等于手指位移，不会出现“拖动被缩放放大”的漂移。
      final position = _startPosition * ratio + focal - _startFocal * ratio;
      final clamped = _clamp(position, settings, newScale);
      _scale = newScale;
      _position = clamped;
      // 拖动/捏合只更新 Transform 子树，不重建整页
      _publishTransform();

      // 3) 单指拖拽且已放大时，记录“顶到边缘后继续往外推”的溢出量。
      //    这里只记录、不切换，真正的切换判断推迟到松开左键时（见 _handleScaleEnd），
      //    避免视频刚碰到边缘就被切走。
      final isSinglePointerDrag =
          details.pointerCount <= 1 && (details.scale - 1.0).abs() < 0.02;
      if (!isSinglePointerDrag || !_isZoomed) {
        _edgeOverflow = 0.0;
        return;
      }
      // 仅在横向意图明显时累积，避免竖向平移误触发切换
      if (drag.dx.abs() <= drag.dy.abs()) {
        _edgeOverflow = 0.0;
        return;
      }
      // 目标位置被 _clamp 挡住后多出来的部分就是“顶到边缘”的溢出量：
      // 正值=顶在右侧边缘继续右推，负值=顶在左侧边缘继续左推。
      _edgeOverflow = position.dx - clamped.dx;
      return;
    }

    // ---- 未放大且单指：按手势主轴分派（横向=进度，纵向=切换） ----
    if (_swipeAxis == _SwipeAxis.none) {
      if (math.max(drag.dx.abs(), drag.dy.abs()) < _axisLockSlop) return;
      _swipeAxis = drag.dx.abs() > drag.dy.abs()
          ? _SwipeAxis.horizontal
          : _SwipeAxis.vertical;
      // 横向滑动开始：以当前播放位置为基准叠加拖动偏移
      _seekStartPosition = _videoPosition;
    }

    if (_swipeAxis == _SwipeAxis.horizontal) {
      _updateSeekPreview(drag.dx);
    } else {
      _swipeDragDy = drag.dy;
    }
  }

  /// 根据横向拖动位移换算进度预览位置（不立即 seek，松手时才提交）。
  void _updateSeekPreview(double dragDx) {
    final duration = _videoDuration;
    if (duration <= Duration.zero) return;
    final viewportWidth = _viewportSize.width;
    if (viewportWidth <= 0) return;

    final deltaMs = (duration.inMilliseconds * (dragDx / viewportWidth))
        .round();
    final targetMs = (_seekStartPosition.inMilliseconds + deltaMs).clamp(
      0,
      duration.inMilliseconds,
    );
    final target = Duration(milliseconds: targetMs);
    if (target == _seekPreview) return;
    setState(() => _seekPreview = target);
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 注意：这些标志必须在 setState 重置之前读出来
    final edgeOverflow = _edgeOverflow; // 松手时仍顶在边缘的溢出量
    final wasZoomed = _isZoomed;
    final axis = _swipeAxis;
    final swipeDy = _swipeDragDy;
    final seekPreview = _seekPreview;
    final velocity = details.velocity.pixelsPerSecond;

    if (_scale <= _minScale + _zoomEpsilon) {
      _scale = _minScale;
      _position = Offset.zero;
    } else {
      // 手势结束时再夹紧一次，防止旋转或尺寸变化后残留越界
      _position = _clampCurrent(settings);
    }
    _edgeOverflow = 0.0;
    _gesturePinched = false;
    _swipeAxis = _SwipeAxis.none;
    _swipeDragDy = 0.0;
    // 手势结束立即落地最终位置
    _publishTransform();

    // ---- 已放大：保留“顶到边缘继续外推 → 切换”的交互 ----
    if (wasZoomed) {
      if (edgeOverflow.abs() >= _edgeSwitchThreshold) {
        if (edgeOverflow > 0) {
          // 顶在右侧边缘继续右推 → 上一个
          _prevVideo();
        } else {
          // 顶在左侧边缘继续左推 → 下一个
          _nextVideo();
        }
      }
      return;
    }

    // ---- 横向滑动：提交进度跳转 ----
    if (axis == _SwipeAxis.horizontal) {
      setState(() => _seekPreview = null);
      if (seekPreview != null) {
        unawaited(_player.seek(seekPreview));
      }
      return;
    }

    // ---- 纵向滑动：上滑看下一个，下滑看上一个 ----
    if (axis == _SwipeAxis.vertical) {
      final swipedUp =
          swipeDy <= -_swipeSwitchThreshold ||
          velocity.dy <= -_swipeSwitchVelocity;
      final swipedDown =
          swipeDy >= _swipeSwitchThreshold ||
          velocity.dy >= _swipeSwitchVelocity;
      if (swipedUp) {
        _nextVideo();
      } else if (swipedDown) {
        _prevVideo();
      }
    }
  }

  void _rotateVideo() {
    setState(() {
      // 累加 90°；渲染时按整数圈数交给 RotatedBox，避免浮点误差累积。
      _rotation += math.pi / 2;
      // 旋转后视频占据的屏幕区域变了，原平移量可能已经越界
      _position = _clampCurrent(
        Provider.of<SettingsProvider>(context, listen: false),
      );
    });
    _publishTransform();
  }

  /// 向左旋转 90°（与 [_rotateVideo] 方向相反）
  void _rotateLeftVideo() {
    setState(() {
      _rotation -= math.pi / 2;
      _position = _clampCurrent(
        Provider.of<SettingsProvider>(context, listen: false),
      );
    });
    _publishTransform();
  }

  /// 时长就绪后应用挂起的接续播放位置。
  void _maybeApplyResumeSeek() {
    final target = _pendingResumeSeek;
    if (target == null || _videoDuration <= Duration.zero) return;
    _pendingResumeSeek = null;
    // 接近结尾的旧进度视为已看完，避免一打开就结束
    if (target >= _videoDuration - const Duration(seconds: 2)) return;
    unawaited(_player.seek(target).catchError((_) {}));
  }

  /// 记录当前视频的播放进度（仅在「接续播放」模式下）。
  ///
  /// 位置接近结尾时视为看完，清除记录，下次从头开始；
  /// [flushNow] 用于换片与退出时立即把进度写入磁盘。
  void _persistCurrentProgress({bool flushNow = false}) {
    final key = _openPath;
    if (key != null && _resumePlaybackEnabled) {
      final position = _videoPosition;
      if (position > Duration.zero) {
        if (_videoDuration > Duration.zero &&
            position >= _videoDuration - const Duration(seconds: 2)) {
          PlaybackProgressService.instance.clear(key);
        } else {
          PlaybackProgressService.instance.record(key, position);
        }
      }
    }
    if (flushNow) PlaybackProgressService.instance.flush();
  }

  /// 离开播放页前的统一收尾：停掉播放，避免页面还没销毁时声音还在继续。
  ///
  /// [Player.dispose] 是异步的，不能保证它来得及在页面切换前停掉原生播放，
  /// 所以退出播放页的每条路径都显式停一次。
  void _stopPlaybackForExit() {
    if (_stoppedForExit) return;
    _stoppedForExit = true;
    _persistCurrentProgress(flushNow: true);
    _slideProvider.stopPlay();
    unawaited(_player.stop().catchError((_) {}));
  }

  /// 安静地销毁一个可能残留在后台的播放器实例。
  ///
  /// 先 stop 再 dispose：stop 能最快让原生层停止出声；即便实例已经销毁，
  /// 抛出的异常也在这里吞掉，不影响新页面。
  static Future<void> _disposePlayerQuietly(Player player) async {
    try {
      await player.stop();
    } catch (_) {
      // 播放器可能已被销毁
    }
    try {
      await player.dispose();
    } catch (_) {
      // 播放器可能已被销毁
    }
  }

  /// 退出播放：停止播放、还原进入播放前的全屏状态，然后返回主界面。
  ///
  /// 还原必须像工具栏返回按钮那样在 pop **之前**完成：dispose 期间 widget 树正在
  /// 拆除，此时做窗口 FFI 调用（SetWindowLongPtr/SetWindowPos）不可靠，窗口状态
  /// 来不及生效，表现为退出播放后主界面仍停留在全屏。
  void _exitPlayback() {
    // 清理移动端临时方向覆盖，恢复到设置里的偏好
    _playerTempOrientation = null;
    _stopPlaybackForExit();
    _restoreFullscreenBeforePlayback();
    final navigator = Navigator.of(context);
    // 延迟一小段时间让窗口状态稳定后再返回
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) navigator.pop();
    });
  }

  /// 关闭应用：与标题栏关闭一致，按设置直接退出或收起到系统托盘。
  void _closeApplication() {
    _stopPlaybackForExit();
    _restoreFullscreenBeforePlayback();
    final navigator = Navigator.of(context);
    // 先回退到进入播放前的页面，托盘恢复时看到的是主界面
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) navigator.pop();
      final tray = DesktopTrayService.instance;
      if (tray != null) unawaited(tray.closeApplication());
    });
  }

  /// 设置播放器音量（0~100）
  void _setVolume(double value) {
    final volume = value.clamp(0.0, 100.0).toDouble();
    _player.setVolume(volume);
    if (mounted) setState(() => _volume = volume);
  }

  /// 音量图标随档位变化：0 静音 / 偏低 / 偏高
  IconData get _volumeIcon {
    if (_volume <= 0) return Icons.volume_off;
    if (_volume < 50) return Icons.volume_down;
    return Icons.volume_up;
  }

  /// 切换播放速度（倍速）
  void _setPlaybackRate(double rate) {
    if (_playbackRate == rate) return;
    setState(() => _playbackRate = rate);
    unawaited(_player.setRate(rate).catchError((_) {}));
    _hideControlsDelayed();
  }

  /// 倍速文案：整数不带小数点，小数保留原始写法
  String _rateLabel(double rate) {
    final text = rate == rate.roundToDouble()
        ? rate.toInt().toString()
        : rate.toString();
    return '$text×';
  }

  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      // Ctrl 组合键缩放：Ctrl + = / Ctrl + - / Ctrl + 0
      if (HardwareKeyboard.instance.isControlPressed) {
        if (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd) {
          _zoomAt(_viewportCenter, _zoomStep);
          return true;
        }
        if (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract) {
          _zoomAt(_viewportCenter, 1 / _zoomStep);
          return true;
        }
        if (key == LogicalKeyboardKey.digit0 ||
            key == LogicalKeyboardKey.numpad0) {
          _resetZoom();
          return true;
        }
      }
      switch (key) {
        case LogicalKeyboardKey.space:
          _togglePlay();
          return true;
        case LogicalKeyboardKey.arrowLeft:
          // 方向键与工具栏一致，使用左右滑动动画
          _prevVideo(trigger: _TransitionTrigger.horizontal);
          return true;
        case LogicalKeyboardKey.arrowRight:
          _nextVideo(trigger: _TransitionTrigger.horizontal);
          return true;
        case LogicalKeyboardKey.arrowUp:
          // 以视口中心为锚点放大
          _zoomAt(_viewportCenter, _zoomStep);
          return true;
        case LogicalKeyboardKey.arrowDown:
          _zoomAt(_viewportCenter, 1 / _zoomStep);
          return true;
        case LogicalKeyboardKey.escape:
          // 菜单打开时 ESC 只关菜单，不退出播放；
          // 否则 ESC 一次直接退出播放（全屏状态在页面销毁时一并恢复，
          // 全屏切换统一交给 F11，ESC 不再负责退出全屏）
          if (_closeContextMenu()) return true;
          _exitPlayback();
          return true;
        case LogicalKeyboardKey.f11:
          if (_isFullscreen) {
            _exitFullscreen();
          } else {
            _enterFullscreen();
          }
          return true;
        case LogicalKeyboardKey.delete:
          // Ctrl+Del：执行与“删除行为”设置相反的动作
          _showDeleteConfirmation(
            invertAction: HardwareKeyboard.instance.isControlPressed,
          );
          return true;
        case LogicalKeyboardKey.keyR:
          _rotateVideo();
          return true;
        case LogicalKeyboardKey.keyL:
          _rotateLeftVideo();
          return true;
        default:
          break;
      }
    }
    return false;
  }

  void _handleScroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      // Ctrl / Shift + 滚轮：执行与“滚轮行为”设置相反的操作
      final modifierPressed =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isShiftPressed;
      final switchVideo = modifierPressed
          ? !settings.wheelSwitchVideo
          : settings.wheelSwitchVideo;
      if (switchVideo) {
        // 滚轮切换视频（不触发工具栏显示）
        if (event.scrollDelta.dy > 0) {
          _nextVideo();
        } else if (event.scrollDelta.dy < 0) {
          _prevVideo();
        }
      } else {
        // 滚轮缩放视频：乘法步长 + 以光标为中心
        final factor = event.scrollDelta.dy > 0 ? 1 / _zoomStep : _zoomStep;
        _zoomAt(event.localPosition, factor);
      }
    } else if (event is PointerScaleEvent) {
      // 触控板双指捏合：按事件给出的倍率以触点为中心缩放
      _zoomAt(event.localPosition, event.scale);
    }
  }

  /// 右键呼出小菜单：放大 / 缩小 / 适应屏幕 / 旋转，以及级联的「播放速度」。
  ///
  /// 用单个 OverlayEntry 渲染自定义菜单（见 [VideoContextMenu]）：一级菜单
  /// 打开后保持显示，二级菜单展开时不再关闭一级；相比两次顺序 showMenu，
  /// 弹出手感更快，交互也更接近系统右键菜单。
  void _showVideoContextMenu(Offset globalPosition) {
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    // 缩放锚点需要相对视口的局部坐标
    final gestureBox =
        _gestureKey.currentContext?.findRenderObject() as RenderBox?;
    final localPosition = gestureBox != null
        ? gestureBox.globalToLocal(globalPosition)
        : _viewportCenter;

    OverlayEntry? entry;
    void close() {
      _contextMenuOpen = false;
      _contextMenuEntry = null;
      entry?.remove();
    }

    entry = OverlayEntry(
      builder: (context) => VideoContextMenu(
        anchor: globalPosition,
        overlaySize: overlayBox.size,
        l10n: AppLocalizations.of(context),
        currentRate: _playbackRate,
        rates: _playbackRates,
        rateLabel: _rateLabel,
        tracks: _tracks,
        currentTrack: _currentTrack,
        onAction: (action) {
          close();
          switch (action) {
            case 'zoomIn':
              _zoomAt(localPosition, _zoomStep);
              break;
            case 'zoomOut':
              _zoomAt(localPosition, 1 / _zoomStep);
              break;
            case 'rotate':
              _rotateVideo();
              break;
          }
        },
        onRateSelected: (rate) {
          close();
          _setPlaybackRate(rate);
        },
        onAudioTrackSelected: (t) => unawaited(_player.setAudioTrack(t)),
        onSubtitleTrackSelected: (t) => unawaited(_player.setSubtitleTrack(t)),
        onClose: close,
      ),
    );
    _contextMenuOpen = true;
    _contextMenuEntry = entry;
    overlay.insert(entry);
  }

  /// 关闭当前右键菜单；未打开时返回 false（供 ESC 分支区分“关菜单 vs 退出播放”）。
  bool _closeContextMenu() {
    if (!_contextMenuOpen || _contextMenuEntry == null) return false;
    _contextMenuOpen = false;
    _contextMenuEntry!.remove();
    _contextMenuEntry = null;
    return true;
  }

  /// 工具栏菜单按钮弹出的菜单：与右键菜单复用同一个 [VideoContextMenu]，
  /// 但锚点是按钮左下角（菜单从按钮下方展开），缩放锚点是视口中心。
  void _showToolbarMenu() {
    // 菜单已打开则再次点击收起
    if (_contextMenuOpen) {
      _closeContextMenu();
      return;
    }
    final buttonContext = _toolbarMenuKey.currentContext;
    if (buttonContext == null) return;
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    if (buttonBox == null) return;

    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    // 菜单锚点 = 按钮左下角（Overlay 全局坐标）
    final buttonOffset = buttonBox.localToGlobal(
      Offset(0, buttonBox.size.height),
      ancestor: overlayBox,
    );
    // 缩放锚点 = 视口中心（工具栏按钮没有"点哪里缩放"的语义）
    final gestureBox =
        _gestureKey.currentContext?.findRenderObject() as RenderBox?;
    final localCenter = gestureBox != null
        ? gestureBox.size.center(Offset.zero)
        : _viewportCenter;

    OverlayEntry? entry;
    void close() {
      _contextMenuOpen = false;
      _contextMenuEntry = null;
      entry?.remove();
    }

    entry = OverlayEntry(
      builder: (context) => VideoContextMenu(
        anchor: buttonOffset,
        overlaySize: overlayBox.size,
        l10n: AppLocalizations.of(context),
        currentRate: _playbackRate,
        rates: _playbackRates,
        rateLabel: _rateLabel,
        tracks: _tracks,
        currentTrack: _currentTrack,
        onAction: (action) {
          close();
          switch (action) {
            case 'zoomIn':
              _zoomAt(localCenter, _zoomStep);
              break;
            case 'zoomOut':
              _zoomAt(localCenter, 1 / _zoomStep);
              break;
            case 'rotate':
              _rotateVideo();
              break;
          }
        },
        onRateSelected: (rate) {
          close();
          _setPlaybackRate(rate);
        },
        onAudioTrackSelected: (t) => unawaited(_player.setAudioTrack(t)),
        onSubtitleTrackSelected: (t) => unawaited(_player.setSubtitleTrack(t)),
        onClose: close,
      ),
    );
    _contextMenuOpen = true;
    _contextMenuEntry = entry;
    overlay.insert(entry);
  }

  /// 文件大小文本：本机文件按路径缓存并异步读盘，远端直接使用服务端返回的大小。
  ///
  /// 切勿在 build 中直接读盘/解码，否则每次重建都会阻塞 UI 线程。
  String _fileSizeLabel(VideoItem item) {
    if (item.isRemote) return _formatSizeBytes(item.sizeBytes);
    final cached = _fileSizeCache[item.path];
    if (cached != null) return cached;
    unawaited(_loadVideoMeta(item.path));
    return '…';
  }

  /// 分辨率文本：优先用播放器解码出的尺寸；
  /// 远端在解码就绪前先用列表里带的真实分辨率兜底。
  String _resolutionLabel(VideoItem item) {
    final w = _videoWidth ?? item.width;
    final h = _videoHeight ?? item.height;
    if (w == null || h == null) return '…';
    return '$w x $h';
  }

  /// 把字节数格式化为 B/KB/MB/GB，未知时显示「未知」。
  String _formatSizeBytes(int? bytes) {
    final unknownText = AppLocalizations.of(context).unknown;
    if (bytes == null || bytes < 0) return unknownText;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 只在磁盘上读取一次文件大小，结果缓存起来。
  Future<void> _loadVideoMeta(String path) async {
    if (_metaLoading.contains(path)) return;
    if (_fileSizeCache.containsKey(path)) return;
    _metaLoading.add(path);
    final unknownText = AppLocalizations.of(context).unknown;
    try {
      final sizeText = await _formatFileSize(File(path), unknownText);
      if (!mounted) return;
      setState(() {
        _fileSizeCache[path] = sizeText;
      });
    } finally {
      _metaLoading.remove(path);
    }
  }

  static Future<String> _formatFileSize(File file, String unknownText) async {
    try {
      final size = await file.length();
      if (size < 1024) return '$size B';
      if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return unknownText;
    }
  }

  /// 根据视频方向设置计算自动旋转角度。
  ///
  /// 依赖 [_intrinsicSize]（由播放器事件流异步填充），不做同步解码。
  /// 若 [_playerTempOrientation] 非 null，则优先使用它。
  double _computeAutoRotation(
    SlideProvider slideProvider,
    SettingsProvider settings,
  ) {
    if (slideProvider.videos.isEmpty) return 0.0;

    final effective = _playerTempOrientation ?? settings.videoOrientation;
    switch (effective) {
      case VideoOrientation.landscape:
        // 强制横屏：如果视频是竖屏的，旋转90°
        return _isPortraitVideo() ? math.pi / 2 : 0.0;
      case VideoOrientation.portrait:
        // 强制竖屏：如果视频是横屏的，旋转90°
        return _isLandscapeVideo() ? math.pi / 2 : 0.0;
      case VideoOrientation.followSystem:
        return 0.0;
      case VideoOrientation.followVideo:
        // 跟随视频：让视频的长边对齐屏幕长边
        return _getRotationToMatchScreen();
    }
  }

  /// 计算让视频长边对齐屏幕长边所需的旋转角度。
  double _getRotationToMatchScreen() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) {
      // 尺寸尚未就绪：先按不旋转处理，尺寸到位后 [_onVideoSizeChanged] 会重算
      return 0.0;
    }

    final size = MediaQuery.of(context).size;
    final isScreenLandscape = size.width >= size.height;
    final isVideoLandscape = intrinsic.width >= intrinsic.height;

    // 如果视频方向和屏幕方向不一致，旋转 90° 使长边对齐
    if (isScreenLandscape != isVideoLandscape) {
      return math.pi / 2;
    }
    return 0.0;
  }

  bool _isPortraitVideo() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.height > intrinsic.width;
  }

  bool _isLandscapeVideo() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.width > intrinsic.height;
  }

  /// 根据设置锁定屏幕方向（移动端使用）。
  ///
  /// 若 [_playerTempOrientation] 非 null，则优先使用它（移动端按钮临时切换覆盖）。
  void _applyScreenOrientation(SettingsProvider settings) {
    final effective = _playerTempOrientation ?? settings.videoOrientation;
    switch (effective) {
      case VideoOrientation.landscape:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case VideoOrientation.portrait:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
      case VideoOrientation.followSystem:
      case VideoOrientation.followVideo:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
    }
  }

  /// 移动端横屏时纵向空间紧张，底部工具栏改用紧凑布局：
  /// 播放键缩到与相邻按钮同高，进度条压扁并收紧与按钮行之间的空隙。
  bool get _compactToolbar =>
      (Platform.isAndroid || Platform.isIOS) &&
      MediaQuery.of(context).orientation == Orientation.landscape;

  /// 移动端手动切换横竖屏（临时覆盖设置里的方向偏好）。
  ///
  /// 退出播放页时由 [dispose] 清理并还原为设置值。
  void _togglePlayerOrientation() {
    final size = MediaQuery.of(context).size;
    final isScreenLandscape = size.width >= size.height;

    VideoOrientation next;
    if (_playerTempOrientation == null) {
      // 未临时锁过：根据当前屏幕方向切到另一侧
      next = isScreenLandscape
          ? VideoOrientation.portrait
          : VideoOrientation.landscape;
    } else {
      // 已临时锁过：在 portrait / landscape 间翻转
      next = _playerTempOrientation == VideoOrientation.landscape
          ? VideoOrientation.portrait
          : VideoOrientation.landscape;
    }

    _playerTempOrientation = next;
    // 记住该视频的方向，下次播放自动恢复
    final key = _openPath;
    if (key != null) {
      unawaited(
        TrackPrefService.instance.save(
          key,
          orientation: next == VideoOrientation.landscape
              ? 'landscape'
              : 'portrait',
        ),
      );
    }
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    _applyScreenOrientation(settings);
    _autoRotation = _computeAutoRotation(slideProvider, settings);
    setState(() {});
  }

  /// 用 [_transitionController] 驱动换片动画。
  ///
  /// 不使用 [AnimatedSwitcher]：多个 [Video] 共用一个 [VideoController]
  /// 会互相抢占视频纹理，因此同一时刻只能挂载一个 [Video]，
  /// 动画只能作用在这唯一的画面上。
  ///
  /// 动画形式由切换入口决定：
  /// - 滚轮 / 手势 / 键盘等手动切换：上下滑动，方向跟随上一个/下一个；
  /// - 工具栏按钮：左右滑动，方向跟随上一个/下一个；
  /// - 播放结束自动切换：淡入淡出。
  Widget _buildTransitionAnimation(Widget child) {
    if (_activeTransition == _TransitionTrigger.auto) {
      return FadeTransition(opacity: _transitionController, child: child);
    }

    // 工具栏与方向键沿水平方向进出；滚轮/手势沿垂直方向进出
    final begin = _activeTransition == _TransitionTrigger.horizontal
        ? Offset(_activeDirection.toDouble(), 0)
        : Offset(0, _activeDirection.toDouble());

    return SlideTransition(
      position: Tween<Offset>(
        begin: begin,
        end: Offset.zero,
      ).animate(_transitionController),
      child: child,
    );
  }

  /// 播放进度显示用的时间文本（不足一小时时省略小时位）。
  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)}';
    }
    return '${two(minutes)}:${two(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 系统返回键 / 返回手势：路由弹出时立即停止播放。
      // 只依赖 dispose 时，停止动作可能在页面切换动画之后才生效，
      // 表现为退出播放页后声音仍在继续。
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _stopPlaybackForExit();
      },
      child: Consumer2<SlideProvider, SettingsProvider>(
        builder: (context, slideProvider, settings, child) {
          // 检测设置变更并即时应用运行时效果（方向、自动隐藏、循环模式等）
          _applySettingsToPlayback(settings);

          if (slideProvider.videos.isEmpty) {
            return Scaffold(
              backgroundColor: settings.background,
              body: Center(child: Text(AppLocalizations.of(context).noVideos)),
            );
          }

          final loc = AppLocalizations.of(context);
          final currentItem = slideProvider.videos[slideProvider.currentIndex];
          // 远端视频可执行的操作由共享终端当前开放的权限决定；
          // 用 record 作为 select 的键，避免（不可比较的）对象每次通知都触发重建
          final remoteActions = currentItem.isRemote
              ? context.select<LanProvider, (bool, bool)>((lan) {
                  final caps = lan.capabilitiesFor(currentItem.deviceId ?? '');
                  return (caps.exclude, caps.copy);
                })
              : (false, false);

          return Scaffold(
            backgroundColor: settings.background,
            body: Focus(
              autofocus: true,
              child: Listener(
                onPointerSignal: _handleScroll,
                // 鼠标悬停移动（未按键）也算一次操作，顺延工具栏自动隐藏计时
                onPointerHover: (_) => _onPointerHoverActivity(),
                // 用于“完全松手”才恢复工具栏：GestureDetector 的 onScaleEnd
                // 无法覆盖“双指后先抬一根手指、另一根继续停住”的情形。
                onPointerDown: (event) {
                  if (_pointerCount == 0) {
                    // 新一轮交互开始，重置手势判定标志
                    // （点按按钮等情形不会走到 onScaleStart）
                    _gestureMoved = false;
                    _gesturePinched = false;
                    _gestureTravel = 0.0;
                    _multiPointerUsed = false;
                    _secondaryButtonUsed = false;
                    // 记下落点，松手时据此区分“点画面”与“点工具栏按钮”
                    _pointerDownPosition = event.position;
                  }
                  // 右键用于呼出小菜单，标记后松手时不当作“轻点画面”
                  if (event.kind == PointerDeviceKind.mouse &&
                      event.buttons == kSecondaryMouseButton) {
                    _secondaryButtonUsed = true;
                  }
                  _pointerCount++;
                  if (_pointerCount > 1) _multiPointerUsed = true;
                },
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerCancel,
                child: LayoutBuilder(
                  // 视频以 Stack 铺满整个 body，因此用它的约束尺寸作为
                  // 缩放/平移的视口尺寸，不再于 build 期间写入实例字段。
                  builder: (context, constraints) {
                    // 仅在约束有限且非空时缓存；写入实例字段不会触发重建
                    final viewport = constraints.biggest;
                    if (viewport.isFinite && !viewport.isEmpty) {
                      _viewportSizeCache = viewport;
                    }
                    return GestureDetector(
                      key: _gestureKey,
                      behavior: HitTestBehavior.opaque,
                      // 注意：不要用 onTapDown 触发工具栏！
                      // onTapDown 在“手指刚按下”就会触发（即使随后变成缩放/拖动），
                      // 于是每次双指缩放都会弹出工具栏。
                      // 这里也不注册 onTap：统一由外层 Listener 在“所有手指抬起”时
                      // 判定本次是否只是轻点（见 _onAllPointersReleased）。
                      //
                      // 只注册缩放识别器、不注册横向拖拽识别器：
                      // 框架断言明确指出“scale 是 pan 的超集”，且拖拽的认定阈值
                      // （kTouchSlop 18）小于缩放的平移阈值（kPanSlop 36），
                      // 两者共存时单指拖动必被拖拽抢走、双指捏合也可能失效。
                      // 统一交给缩放识别器后，按主轴在代码里分派：
                      //   · 未放大 + 横向 → 拖动进度条（见 _handleScaleUpdate/End）
                      //   · 未放大 + 纵向 → 上滑下一个 / 下滑上一个
                      //   · 已放大        → 单指拖动平移 + 顶到边缘继续外推切换
                      onScaleStart: _handleScaleStart,
                      onScaleUpdate: _handleScaleUpdate,
                      onScaleEnd: _handleScaleEnd,
                      onSecondaryTapUp: (details) =>
                          _showVideoContextMenu(details.globalPosition),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildTransitionAnimation(
                            ValueListenableBuilder<_ViewTransform>(
                              valueListenable: _viewTransform,
                              // 拖动/缩放只需要移动这一层；视频与旋转子树保持不变
                              child: SizedBox.expand(
                                child: RotatedBox(
                                  // 布局阶段旋转：RotatedBox 会把父级约束沿对角翻转
                                  // 后再交给视频适配，于是 contain 的短边能真正贴满
                                  // 屏幕短边（与 [_displayBaseSize] 的算法一致）。
                                  quarterTurns: _quarterTurns,
                                  child: Video(
                                    controller: _videoController,
                                    fit: settings.boxFit,
                                    fill: settings.background,
                                    // 播放控制由本页自己的工具栏负责，
                                    // 关闭 media_kit 自带控件避免重复。
                                    controls: null,
                                    // 常亮已由本页的 WakelockPlus 统一管理。
                                    wakelock: false,
                                  ),
                                ),
                              ),
                              builder: (context, transform, child) => Transform(
                                alignment: Alignment.center,
                                // 顺序很重要：Matrix4 的方法是在右侧相乘，
                                // 因此 M = T · S。平移在最外层，position 才是纯屏幕
                                // 像素，与 [_clamp] 的边界计算保持一致；
                                // 若把 translate 写在最后（M = S · T），位移会被缩放放大。
                                //
                                // 旋转不放在这里：Transform 只在绘制阶段旋转，会把
                                // 「已按视口适配好的整块区域」连黑边一起转过来，导致
                                // contain 下旋转 90° 后四周都是黑边、短边填不满。
                                // 旋转改由上面的 RotatedBox 在布局阶段完成。
                                transform: Matrix4.identity()
                                  ..translateByVector3(
                                    vector.Vector3(
                                      transform.position.dx,
                                      transform.position.dy,
                                      0,
                                    ),
                                  )
                                  ..scaleByVector3(
                                    vector.Vector3(
                                      transform.scale,
                                      transform.scale,
                                      transform.scale,
                                    ),
                                  ),
                                child: child,
                              ),
                            ),
                          ),
                          // 播放错误提示（解码失败等）
                          if (_playbackError != null)
                            Center(
                              child: Text(
                                AppLocalizations.of(context).videoLoadFailed,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          // 缓冲中提示
                          if (_buffering && _playbackError == null)
                            const Center(
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          if (_showControls)
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: AppBar(
                                key: _topControlsKey,
                                backgroundColor: Colors.black.withValues(
                                  alpha: 0.5,
                                ),
                                title: Text(
                                  '${slideProvider.currentIndex + 1} / ${slideProvider.videos.length}',
                                  style: const TextStyle(fontSize: 16),
                                ),
                                leading: Tooltip(
                                  message: AppLocalizations.of(context).back,
                                  child: IconButton(
                                    icon: const Icon(Icons.arrow_back),
                                    onPressed: _exitPlayback,
                                  ),
                                ),
                                actions: [
                                  // 菜单按钮：放在所有按钮最前面，复用右键菜单的内容
                                  Tooltip(
                                    message: AppLocalizations.of(
                                      context,
                                    ).showMenu,
                                    child: IconButton(
                                      key: _toolbarMenuKey,
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: _showToolbarMenu,
                                    ),
                                  ),
                                  // 全屏/退出全屏按钮仅在 Windows 桌面端显示
                                  // （手机端播放本身即全屏，无需切换）
                                  if (Platform.isWindows)
                                    Tooltip(
                                      message: _isFullscreen
                                          ? AppLocalizations.of(
                                              context,
                                            ).exitFullscreen
                                          : AppLocalizations.of(
                                              context,
                                            ).enterFullscreen,
                                      child: IconButton(
                                        icon: Icon(
                                          _isFullscreen
                                              ? Icons.fullscreen_exit
                                              : Icons.fullscreen,
                                        ),
                                        onPressed: _isFullscreen
                                            ? _exitFullscreen
                                            : _enterFullscreen,
                                      ),
                                    ),
                                  // 远端视频：按共享终端开放的权限显示「排除 / 复制」
                                  if (currentItem.isRemote && remoteActions.$1)
                                    Tooltip(
                                      message: loc.excludeFromPlay,
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.block,
                                          color: Colors.orange,
                                        ),
                                        onPressed: () => _deleteCurrentVideo(
                                          DeleteAction.exclude,
                                        ),
                                      ),
                                    ),
                                  if (currentItem.isRemote && remoteActions.$2)
                                    Tooltip(
                                      message: loc.lanCopyToLocal,
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.download,
                                          color: Colors.white,
                                        ),
                                        onPressed: _copyCurrentVideo,
                                      ),
                                    ),
                                  // 本地视频保持排除/删除按钮（跟随删除行为设置）
                                  if (!currentItem.isRemote)
                                    Tooltip(
                                      message:
                                          settings.deleteAction ==
                                              DeleteAction.exclude
                                          ? loc.excludeFromPlay
                                          : loc.deleteFileLabel,
                                      child: IconButton(
                                        icon: Icon(
                                          settings.deleteAction ==
                                                  DeleteAction.exclude
                                              ? Icons.block
                                              : Icons.delete,
                                          color:
                                              settings.deleteAction ==
                                                  DeleteAction.exclude
                                              ? Colors.orange
                                              : Colors.red,
                                        ),
                                        onPressed: _showDeleteConfirmation,
                                      ),
                                    ),
                                  Tooltip(
                                    message: AppLocalizations.of(
                                      context,
                                    ).rotate,
                                    child: IconButton(
                                      icon: const Icon(Icons.rotate_right),
                                      onPressed: _rotateVideo,
                                    ),
                                  ),
                                  Tooltip(
                                    message: AppLocalizations.of(
                                      context,
                                    ).settings,
                                    child: IconButton(
                                      icon: const Icon(Icons.settings),
                                      onPressed: () => Navigator.pushNamed(
                                        context,
                                        '/settings',
                                      ),
                                    ),
                                  ),
                                  // 桌面端关闭按钮：按设置直接退出或收起到系统托盘
                                  if (Platform.isWindows)
                                    Tooltip(
                                      message: AppLocalizations.of(
                                        context,
                                      ).closeApp,
                                      child: IconButton(
                                        icon: const Icon(Icons.close),
                                        onPressed: _closeApplication,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (_showControls)
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                key: _bottomControlsKey,
                                color: Colors.black.withValues(alpha: 0.5),
                                // 横屏紧凑模式只留很窄的垂直内边距；
                                // 底部再补上系统手势/导航条的安全区，
                                // 否则贴底的按钮行会被屏幕边缘吃掉一截
                                padding: _compactToolbar
                                    ? EdgeInsets.fromLTRB(
                                        16,
                                        4,
                                        16,
                                        4 +
                                            MediaQuery.viewPaddingOf(
                                              context,
                                            ).bottom,
                                      )
                                    : const EdgeInsets.all(16),
                                child: Column(
                                  children: [
                                    if (settings.showVideoInfo && _showInfo)
                                      Padding(
                                        padding: EdgeInsets.only(
                                          bottom: _compactToolbar ? 4 : 12,
                                        ),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                slideProvider
                                                    .videos[slideProvider
                                                        .currentIndex]
                                                    .name,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.white,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(width: 16),
                                              Text(
                                                _fileSizeLabel(
                                                  slideProvider
                                                      .videos[slideProvider
                                                      .currentIndex],
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              Text(
                                                _resolutionLabel(
                                                  slideProvider
                                                      .videos[slideProvider
                                                      .currentIndex],
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    // 播放进度条：可拖拽跳转，也反映左右滑动的预览
                                    Row(
                                      children: [
                                        Text(
                                          _formatDuration(
                                            _seekPreview ?? _videoPosition,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white,
                                          ),
                                        ),
                                        Expanded(
                                          child: SizedBox(
                                            // 紧凑模式下把进度条压扁，
                                            // 消掉 Slider 默认 48dp 行高带来的上下留白
                                            height: _compactToolbar ? 20 : null,
                                            child: SliderTheme(
                                              data: _compactToolbar
                                                  ? SliderTheme.of(
                                                      context,
                                                    ).copyWith(
                                                      trackHeight: 3,
                                                      thumbShape:
                                                          const RoundSliderThumbShape(
                                                            enabledThumbRadius:
                                                                5,
                                                          ),
                                                      overlayShape:
                                                          const RoundSliderOverlayShape(
                                                            overlayRadius: 9,
                                                          ),
                                                    )
                                                  : SliderTheme.of(context),
                                              child: Slider(
                                                value:
                                                    (_seekPreview ??
                                                            _videoPosition)
                                                        .inMilliseconds
                                                        .clamp(
                                                          0,
                                                          math.max(
                                                            _videoDuration
                                                                .inMilliseconds,
                                                            1,
                                                          ),
                                                        )
                                                        .toDouble(),
                                                max: math
                                                    .max(
                                                      _videoDuration
                                                          .inMilliseconds,
                                                      1,
                                                    )
                                                    .toDouble(),
                                                onChanged: (value) {
                                                  if (_videoDuration <=
                                                      Duration.zero) {
                                                    return;
                                                  }
                                                  setState(
                                                    () =>
                                                        _seekPreview = Duration(
                                                          milliseconds: value
                                                              .round(),
                                                        ),
                                                  );
                                                },
                                                // 拖动进度条时不要被自动隐藏计时打断
                                                onChangeStart: (value) {
                                                  _hideControlsTimer?.cancel();
                                                },
                                                onChangeEnd: (value) {
                                                  final target = Duration(
                                                    milliseconds: value.round(),
                                                  );
                                                  setState(
                                                    () => _seekPreview = null,
                                                  );
                                                  unawaited(
                                                    _player.seek(target),
                                                  );
                                                  _hideControlsDelayed();
                                                },
                                              ),
                                            ),
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(_videoDuration),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white,
                                          ),
                                        ),
                                        // 移动端横竖屏临时切换：放在进度条右侧、时长文本之后
                                        if (Platform.isAndroid ||
                                            Platform.isIOS)
                                          Tooltip(
                                            message:
                                                _playerTempOrientation ==
                                                    VideoOrientation.landscape
                                                ? AppLocalizations.of(
                                                    context,
                                                  ).toggleScreenPortrait
                                                : AppLocalizations.of(
                                                    context,
                                                  ).toggleScreenLandscape,
                                            child: IconButton(
                                              padding: EdgeInsets.zero,
                                              // 紧凑模式下跟着进度条一起压扁，
                                              // 否则它会把这行撑回 32dp 高
                                              constraints: _compactToolbar
                                                  ? const BoxConstraints(
                                                      minWidth: 26,
                                                      minHeight: 20,
                                                    )
                                                  : const BoxConstraints(
                                                      minWidth: 32,
                                                      minHeight: 32,
                                                    ),
                                              iconSize: _compactToolbar
                                                  ? 18
                                                  : 22,
                                              // 图标固定用旋转图标，不随当前方向变化
                                              icon: const Icon(
                                                Icons.screen_rotation,
                                              ),
                                              onPressed:
                                                  _togglePlayerOrientation,
                                            ),
                                          ),
                                      ],
                                    ),
                                    Row(
                                      // 手机端去掉固定大间距并均匀铺满宽度：
                                      // 两侧按钮数量与宽度对称，播放键自然居中
                                      mainAxisAlignment:
                                          (Platform.isAndroid || Platform.isIOS)
                                          ? MainAxisAlignment.spaceEvenly
                                          : MainAxisAlignment.center,
                                      children: [
                                        // 单一循环：只循环当前视频，播完不跳下一个。
                                        // 与设置页的「循环播放」（整批播完后的行为）互不影响。
                                        // 图标比相邻的主按钮小一档。
                                        Tooltip(
                                          message: AppLocalizations.of(
                                            context,
                                          ).singleLoop,
                                          child: IconButton(
                                            icon: Icon(
                                              _singleLoop
                                                  ? Icons.repeat_one
                                                  : Icons.repeat,
                                              size: 24,
                                              color: _singleLoop
                                                  ? Colors.lightBlueAccent
                                                  : Colors.white,
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 36,
                                              minHeight: 36,
                                            ),
                                            padding: EdgeInsets.zero,
                                            onPressed: () {
                                              setState(
                                                () =>
                                                    _singleLoop = !_singleLoop,
                                              );
                                              _applyPlaylistMode();
                                            },
                                          ),
                                        ),
                                        if (!Platform.isAndroid &&
                                            !Platform.isIOS)
                                          const SizedBox(width: 16),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.skip_previous,
                                            size: 36,
                                          ),
                                          color: Colors.white,
                                          // 紧凑模式去掉按钮自带的 8dp 上下内边距，
                                          // 否则这行会被撑到 52dp，与进度条之间多出一截空隙
                                          padding: _compactToolbar
                                              ? EdgeInsets.zero
                                              : null,
                                          constraints: _compactToolbar
                                              ? const BoxConstraints(
                                                  minWidth: 36,
                                                  minHeight: 36,
                                                )
                                              : null,
                                          onPressed: () {
                                            _prevVideo(
                                              trigger:
                                                  _TransitionTrigger.horizontal,
                                            );
                                            _showControlsTemporarily();
                                          },
                                        ),
                                        if (!Platform.isAndroid &&
                                            !Platform.isIOS)
                                          const SizedBox(width: 32),
                                        IconButton(
                                          icon: Icon(
                                            // 播放完毕（或已暂停）时显示播放图标
                                            slideProvider.isPlaying &&
                                                    !_completed
                                                ? Icons.pause_circle
                                                : Icons.play_circle,
                                            // 横屏紧凑模式下与相邻按钮同尺寸
                                            size: _compactToolbar ? 36 : 64,
                                          ),
                                          color: Colors.white,
                                          padding: _compactToolbar
                                              ? EdgeInsets.zero
                                              : null,
                                          constraints: _compactToolbar
                                              ? const BoxConstraints(
                                                  minWidth: 36,
                                                  minHeight: 36,
                                                )
                                              : null,
                                          onPressed: _togglePlay,
                                        ),
                                        if (!Platform.isAndroid &&
                                            !Platform.isIOS)
                                          const SizedBox(width: 32),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.skip_next,
                                            size: 36,
                                          ),
                                          color: Colors.white,
                                          padding: _compactToolbar
                                              ? EdgeInsets.zero
                                              : null,
                                          constraints: _compactToolbar
                                              ? const BoxConstraints(
                                                  minWidth: 36,
                                                  minHeight: 36,
                                                )
                                              : null,
                                          onPressed: () {
                                            _nextVideo(
                                              trigger:
                                                  _TransitionTrigger.horizontal,
                                            );
                                            _showControlsTemporarily();
                                          },
                                        ),
                                        if (!Platform.isAndroid &&
                                            !Platform.isIOS)
                                          const SizedBox(width: 16),
                                        // 音量：控制播放器自身音量（0~100）。
                                        // 弹出的是竖向滑杆：最小值在下、最大值在上。
                                        PopupMenuButton<double>(
                                          tooltip: AppLocalizations.of(
                                            context,
                                          ).volume,
                                          icon: Icon(
                                            _volumeIcon,
                                            size: 24,
                                            color: Colors.white,
                                          ),
                                          constraints: const BoxConstraints(
                                            minWidth: 36,
                                            minHeight: 36,
                                          ),
                                          padding: EdgeInsets.zero,
                                          itemBuilder: (context) {
                                            // 弹层打开期间的本地预览音量：拖动中只改这里，
                                            // 松手才写回播放器与页面状态。避免每个像素都触发
                                            // mpv 调用与整页重建，也避免语义值高频抖动
                                            // （Windows 无障碍层会在此时进入引擎的
                                            // 无障碍路径，深递归导致崩溃）。
                                            var previewVolume = _volume;
                                            return [
                                              PopupMenuItem<double>(
                                                // enabled: false 让滑杆自己接收手势，
                                                // 点击/拖动滑杆时不会把菜单一起关掉
                                                enabled: false,
                                                padding: EdgeInsets.zero,
                                                // 该弹层不向无障碍层暴露语义：拖动时数值
                                                // 高频变化，会诱发 UIA 在引擎无障碍路径上
                                                // 深递归崩溃
                                                child: ExcludeSemantics(
                                                  child: SizedBox(
                                                    width: 56,
                                                    height: 180,
                                                    child: StatefulBuilder(
                                                      builder: (context, setPopupState) => Column(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: [
                                                          // 数值用未旋转的 Text 单独显示，
                                                          // 否则会被 RotatedBox 一起竖起来
                                                          Text(
                                                            previewVolume
                                                                .round()
                                                                .toString(),
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 13,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Expanded(
                                                            child: RotatedBox(
                                                              // 3 个 quarterTurns =
                                                              // 逆时针 90°，滑杆由横向变竖向
                                                              quarterTurns: 3,
                                                              child: Slider(
                                                                value: previewVolume
                                                                    .clamp(
                                                                      0.0,
                                                                      100.0,
                                                                    )
                                                                    .toDouble(),
                                                                max: 100,
                                                                divisions: 100,
                                                                // 拖动中只更新弹层预览
                                                                onChanged: (value) {
                                                                  setPopupState(
                                                                    () {
                                                                      previewVolume =
                                                                          value;
                                                                    },
                                                                  );
                                                                },
                                                                // 松手才真正写回播放器，
                                                                // 并收起弹层、重启工具栏自动隐藏计时
                                                                onChangeEnd: (value) {
                                                                  _setVolume(
                                                                    value,
                                                                  );
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop();
                                                                  _hideControlsDelayed();
                                                                },
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ];
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          // 横向滑动拖动进度时，居中显示预览时间
                          // （工具栏隐藏时也能看到拖动反馈）
                          if (_seekPreview != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.6,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '${_formatDuration(_seekPreview!)} / ${_formatDuration(_videoDuration)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          // 删除通知覆盖层
                          if (_showDeleteMessage)
                            Positioned(
                              top: 100,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.8),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _deleteMessageText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          // 全屏播放时鼠标应与工具栏同时隐藏、同时出现：
                          // 工具栏隐藏期间在最上层铺一层「不显示光标」的透明区域。
                          // opaque:false 保证它不拦截下方控件。
                          if (!_showControls)
                            const MouseRegion(
                              cursor: SystemMouseCursors.none,
                              opaque: false,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
