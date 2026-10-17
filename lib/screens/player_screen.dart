import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import 'package:steam_flow/providers/slide_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/services/fullscreen_service.dart';
import 'package:steam_flow/utils/rotated_fit.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:wakelock_plus/wakelock_plus.dart';

/// 在后台 isolate 中解码图片并取回原始像素尺寸。
///
/// 顶层函数才能作为 [compute] 的入口；返回 null 表示解码失败。
Size? _decodeImageSize(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    return Size(image.width.toDouble(), image.height.toDouble());
  } catch (_) {
    return null;
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Timer? _autoPlayTimer;
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

  /// 顶部工具栏（AppBar）、底部按钮行的位置引用，
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

  // ---- 图片缩放/平移 ----
  /// 最小缩放倍数（1.0 即“适应屏幕”）
  static const double _minScale = 1.0;

  /// 最大缩放倍数
  static const double _maxScale = 5.0;

  /// 判定“已放大”的浮点容差
  static const double _zoomEpsilon = 0.01;

  /// 松手切图阈值：拖到边缘后向外推超过该像素数，松开左键才切到上一张/下一张。
  /// 既避免“刚碰到边缘就被切走”，也避免轻微抖动误触发。
  static const double _edgeSwitchThreshold = 24.0;

  /// 未放大时按滑动速度切换图片的阈值（逻辑像素/秒）
  static const double _swipeVelocityThreshold = 50.0;

  double _scale = 1.0;
  double _rotation = 0.0;
  Offset _position = Offset.zero;
  Offset _startPosition = Offset.zero;
  double _startScale = 1.0;

  /// 手势开始时焦点相对视口中心的位置
  Offset _startFocal = Offset.zero;

  /// 视口尺寸（由 [LayoutBuilder] 的布局结果缓存）。
  /// 在 build 期间只写入这个字段（而非 _viewportCenter），
  /// 视口中心由 [_viewportCenter] 计算得到。
  Size? _viewportSizeCache;

  /// 单指拖拽已放大的图片时，累计的“超出边界”横向溢出量：
  /// 正值=顶在右侧边缘并继续往外推，负值=顶在左侧边缘并继续往外推。
  ///
  /// 拖拽过程中不切图，只有松开左键时才据此判断是否切换上一张/下一张。
  double _edgeOverflow = 0.0;

  /// 本次手势中是否出现过捏合（双指缩放）。
  /// 用于在松手时区分“滑动切图”与“捏合缩放”，避免缩回原尺寸时误翻页。
  bool _gesturePinched = false;

  /// 是否因为“放大查看”而暂停了自动播放。
  ///
  /// 与“用户主动暂停”区分开：前者在缩放回原尺寸后需要自动恢复播放，
  /// 后者必须保持暂停。
  bool _zoomSuspended = false;

  /// 滚轮/键盘缩放的乘法步长（每次 ×[_zoomStep] 或 ÷[_zoomStep]）
  static const double _zoomStep = 1.1;

  /// 本轮交互是否用过右键（右键用于呼出小菜单，不应被当成“轻点画面”切换工具栏）
  bool _secondaryButtonUsed = false;

  /// 当前图片的原始像素尺寸，用于计算平移边界
  Size? _intrinsicSize;
  int _intrinsicSizeForIndex = -1;
  ImageStream? _intrinsicStream;
  ImageStreamListener? _intrinsicListener;

  /// 包裹图片区域的 GestureDetector，用于取得真实视口尺寸
  final GlobalKey _gestureKey = GlobalKey();

  bool _wasPlayingBeforeDelete = false;
  bool _showDeleteMessage = false;
  String _deleteMessageText = '';
  double _autoRotation = 0.0;
  int _lastProcessedIndex = -1;

  /// 文件大小与分辨率缓存的加载中标记（防止重复请求）
  final Set<String> _metaLoading = {};

  // ---- 图片元信息缓存（避免在 build 中同步解码/读盘） ----
  /// 缓存的文件大小与分辨率文本，键为图片路径。
  /// 原先这两个信息在 build 里同步调用（含整张图片解码），
  /// 触摸显示工具栏时会导致每帧解码一次 → 手势严重掉帧。
  final Map<String, String> _fileSizeCache = {};
  final Map<String, String> _resolutionCache = {};

  // 记录最近一次已应用的运行时设置，用于检测设置变更并及时应用
  int _lastInterval = -1;
  ImageOrientation _lastOrientation = ImageOrientation.followSystem;
  int _lastControlsHideDelay = -1;
  bool _lastHideToolbar = true;
  int _lastInfoHideDelay = -1;
  bool _lastInfoAutoHide = true;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 播放时保持屏幕常亮，避免进入省电模式自动熄屏
    WakelockPlus.enable();

    // 初始化最近一次设置快照，避免首帧误判为设置变更
    _lastInterval = settings.interval;
    _lastOrientation = settings.imageOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastInfoHideDelay = settings.infoHideDelay;
    _lastInfoAutoHide = settings.infoAutoHide;

    // 注册全局键盘监听器，不依赖 FocusNode
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 请求焦点以接收键盘事件

      // 如果设置了自动全屏，先进入全屏再开始播放。
      // 手机端应用本身就是独占全屏的，不存在窗口化的「全屏」概念，
      // 因此该设置只对桌面端生效（设置页在手机端也不展示这一项）。
      final startFullscreen =
          settings.startFullscreen && !Platform.isAndroid && !Platform.isIOS;
      if (startFullscreen) {
        // 延迟更长时间再进入全屏，确保窗口完全就绪
        Future.delayed(const Duration(milliseconds: 300), () {
          _enterFullscreen();

          // 全屏后再延迟一小段时间启动自动播放，确保窗口状态稳定
          Future.delayed(const Duration(milliseconds: 100), () {
            if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
              _startAutoPlay();
            }
          });
        });
      } else if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
        // 如果正处于播放状态，启动自动播放定时器
        _startAutoPlay();
      }

      // 应用屏幕方向设置
      _applyScreenOrientation(settings);

      // 在播放状态确定后再设置自动隐藏
      _hideControlsDelayed();
      _hideInfoDelayed();
    });
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 避免每次更新都重启定时器
  }

  /// 检测设置变更并将运行时效果（轮播间隔、屏幕方向、自动隐藏等）即时应用。
  /// 由于 build 中不能调用 setState，将真正应用动作延迟到本次 build 完成后执行。
  void _applySettingsToPlayback(SettingsProvider settings) {
    final intervalChanged = settings.interval != _lastInterval;
    final orientationChanged = settings.imageOrientation != _lastOrientation;
    final controlsChanged =
        settings.controlsHideDelay != _lastControlsHideDelay ||
        settings.hideToolbar != _lastHideToolbar;
    final infoChanged =
        settings.infoHideDelay != _lastInfoHideDelay ||
        settings.infoAutoHide != _lastInfoAutoHide;

    _lastInterval = settings.interval;
    _lastOrientation = settings.imageOrientation;
    _lastControlsHideDelay = settings.controlsHideDelay;
    _lastHideToolbar = settings.hideToolbar;
    _lastInfoHideDelay = settings.infoHideDelay;
    _lastInfoAutoHide = settings.infoAutoHide;

    if (!intervalChanged &&
        !orientationChanged &&
        !controlsChanged &&
        !infoChanged) {
      return;
    }

    // 延迟到 build 完成后应用，避免 build 中调用 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (intervalChanged) {
        _startAutoPlay();
      }
      if (orientationChanged) {
        _applyScreenOrientation(settings);
      }
      if (controlsChanged) {
        _hideControlsDelayed();
      }
      if (infoChanged) {
        _hideInfoDelayed();
      }
    });
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _hideControlsTimer?.cancel();
    _hideInfoTimer?.cancel();
    // 释放用于读取图片尺寸的图片流监听
    _detachIntrinsicSizeListener();
    // 移除全局键盘监听器
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);

    // 释放屏幕常亮，恢复系统正常熄屏行为
    WakelockPlus.disable();

    // 确保退出全屏状态，但不调用 setState
    if (_isFullscreen) {
      FullscreenService.instance.exit();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 恢复所有屏幕方向
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /// 暂停播放
  void _pausePlayback() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 保存当前播放状态
    _wasPlayingBeforeDelete = slideProvider.isPlaying;
    if (slideProvider.isPlaying) {
      slideProvider.stopPlay();
    }
    _autoPlayTimer?.cancel();
  }

  /// 恢复播放
  void _resumePlayback() {
    // 只有在暂停前是播放状态时才恢复播放
    if (!_wasPlayingBeforeDelete) return;

    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (!slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
      slideProvider.startPlay();
      _startAutoPlay();
    }
  }

  /// 显示播放完毕提示对话框
  void _showPlaybackCompleteDialog() {
    // 如果当前是全屏状态，先退出全屏再显示对话框
    if (_isFullscreen) {
      _exitFullscreen();
      // 延迟一小段时间让窗口状态稳定后再显示对话框
      Future.delayed(const Duration(milliseconds: 200), () {
        _showPlaybackCompleteAlert();
      });
    } else {
      _showPlaybackCompleteAlert();
    }
  }

  /// 实际显示播放完毕提示对话框
  void _showPlaybackCompleteAlert() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false, // 必须点击确认才能关闭
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).playbackComplete),
        content: Text(AppLocalizations.of(context).allImagesPlayed),
        actions: [
          TextButton(
            onPressed: () {
              // 返回主界面
              Navigator.pop(context); // 关闭对话框
              Navigator.pop(context); // 返回主界面
            },
            child: Text(AppLocalizations.of(context).confirm),
          ),
        ],
      ),
    );
  }

  /// 处理删除操作
  /// 删除当前图片。
  /// [invertAction] 为 true 时执行与“删除行为”设置相反的动作（对应 Ctrl+Del）。
  void _showDeleteConfirmation({bool invertAction = false}) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final action = _effectiveDeleteAction(settings, invertAction);

    // 如果是排除播放，直接执行操作，不需要确认，也不需要退出全屏
    if (action == DeleteAction.exclude) {
      _deleteCurrentImage(action);
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

    final currentImage = slideProvider.images[slideProvider.currentIndex];
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
          '${AppLocalizations.of(context).confirmDeleteMsg(deleteActionText)}\n\n${currentImage.name}',
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
              final imagesRemain = await _deleteCurrentImage(action);
              if (imagesRemain) {
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

  /// 删除当前图片（[action] 为本次实际使用的删除行为）
  /// 返回 true 表示图片列表不为空，false 表示图片列表为空且已返回主界面
  Future<bool> _deleteCurrentImage(DeleteAction action) async {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final currentIndex = slideProvider.currentIndex;
    final currentImage = slideProvider.images[currentIndex];

    if (action == DeleteAction.delete) {
      // 实际删除文件
      try {
        await File(currentImage.path).delete();
      } catch (e) {
        // 文件删除失败，可能是文件被占用（使用自定义覆盖层，在全屏模式下也能显示）
        if (mounted) {
          _showDeleteNotification(AppLocalizations.of(context).deleteFailed);
        }
        return true;
      }
    } else if (action == DeleteAction.exclude) {
      // 排除播放：记录到已排除列表，供"选择文件夹"页面的"已排除的文件"使用
      settings.addExcludedPath(currentImage.path);
    }

    // 从播放列表中移除
    slideProvider.removeImage(currentIndex);

    // 如果图片列表为空，返回主界面
    if (slideProvider.images.isEmpty) {
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

  void _startAutoPlay() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    _autoPlayTimer?.cancel();

    // 根据当前播放状态启动或停止定时器
    if (slideProvider.isPlaying && slideProvider.images.isNotEmpty) {
      _autoPlayTimer = Timer.periodic(
        Duration(milliseconds: settings.interval),
        (_) => _nextImage(),
      );
    }
  }

  /// 切换下一张图片。
  /// [manual] 为 true 表示由用户手动触发（键盘/滚轮/滑动/工具栏按钮），
  /// 切换后需要重置自动播放计时器。
  void _nextImage({bool manual = false}) {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);

    // 放大查看细节时不自动切图，避免用户正在看时被定时器切走
    if (!manual && _isZoomed) return;

    if (_scale != _minScale) {
      setState(() {
        _scale = _minScale;
        _rotation = 0.0;
        _position = Offset.zero;
        _edgeOverflow = 0.0;
        // 切图后回到原尺寸，不再需要“放大暂停”标记
        _zoomSuspended = false;
      });
    }

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (!settings.loopPlay) {
      // 顺序/最新/最旧模式：检查是否到达最后一张图片
      final isSequentialOrder =
          settings.playOrder == PlayOrder.sequential ||
          settings.playOrder == PlayOrder.reverseSequential ||
          settings.playOrder == PlayOrder.newestFirst ||
          settings.playOrder == PlayOrder.oldestFirst;
      if (isSequentialOrder &&
          slideProvider.currentIndex == slideProvider.images.length - 1) {
        slideProvider.stopPlay();
        _autoPlayTimer?.cancel();

        // 检查 widget 是否还挂载，避免在已销毁后调用 showDialog
        if (mounted) {
          // 显示播放完毕提示，用户确认后返回主界面
          _showPlaybackCompleteDialog();
        }
        return;
      }

      // 随机播放时，检查是否到达随机序列的最后一个位置
      if (settings.playOrder == PlayOrder.random &&
          slideProvider.isRandomPlaybackComplete()) {
        slideProvider.stopPlay();
        _autoPlayTimer?.cancel();

        // 检查 widget 是否还挂载，避免在已销毁后调用 showDialog
        if (mounted) {
          // 显示播放完毕提示，用户确认后返回主界面
          _showPlaybackCompleteDialog();
        }
        return;
      }
    }

    if (settings.playOrder == PlayOrder.random) {
      // 使用预打乱的随机序列进行播放
      slideProvider.nextRandomImage();
    } else {
      // 顺序/最新优先/最旧优先统一使用顺序索引播放
      slideProvider.nextImage();
    }

    // 手动切换后重置自动播放计时器，让下一张的等待时间从当前时刻重新计算
    if (manual) {
      _startAutoPlay();
    }
  }

  /// 手动切换到上一张图片（键盘/滚轮/滑动/工具栏按钮触发）。
  /// 切换后重置自动播放计时器，让等待时间从当前时刻重新计算。
  void _prevImage() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 切图后回到「适应屏幕」状态，避免新图带着上一张的缩放/位移
    if (_scale != _minScale) {
      setState(() {
        _scale = _minScale;
        _rotation = 0.0;
        _position = Offset.zero;
        _edgeOverflow = 0.0;
        // 切图后回到原尺寸，不再需要“放大暂停”标记
        _zoomSuspended = false;
      });
    }
    Provider.of<SlideProvider>(
      context,
      listen: false,
    ).prevImage(playOrder: settings.playOrder);
    _startAutoPlay();
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

  void _hideInfoDelayed() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _hideInfoTimer?.cancel();
    if (settings.infoAutoHide) {
      _hideInfoTimer = Timer(
        Duration(seconds: settings.infoHideDelay),
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
  /// 若本次只是“轻点”（没有位移、没有捏合、也没触发切图），
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
    // 双指捏合、有位移的拖动（含放大后的平移/松手切图）都不会走到这里切换工具栏。
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
      // 让“点按钮”意外带出图片信息栏。
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

  /// 只在手势确实已经结束（没有任何指针按下）时才隐藏工具栏。
  ///
  /// 缩放大图时用户可能连续多次捏合/拖动，中途松手又立刻按下，
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

    // 放大查看时自动播放已暂停，此时点击播放按钮表示“这张已经看完”：
    // 由 _nextImage 复位缩放/旋转并直接切到下一张，而不是停在原图等换片时间
    if (_zoomSuspended) {
      _nextImage(manual: true);
      return;
    }

    slideProvider.togglePlay();

    // 如果现在是播放状态，启动定时器；否则停止
    if (slideProvider.isPlaying) {
      _startAutoPlay();
      _hideControlsDelayed();
    } else {
      _autoPlayTimer?.cancel();
      // 调用 _hideControlsDelayed() 来应用暂停时保持工具栏的逻辑
      _hideControlsDelayed();
    }
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

  /// 图片在屏幕上显示的实际尺寸（未缩放）。
  ///
  /// 图片用 `Transform(scale:)` 缩放，所以这里的返回值是“缩放前”的尺寸；
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

  /// 把平移量限制在图片边界内
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

    setState(() {
      _scale = newScale;
      // 缩回原尺寸时平移量必须归零，否则整张图会偏离视口中心
      _position = zoomed ? _clamp(adjusted, settings, newScale) : Offset.zero;
    });
    _syncAutoPlayWithZoom();
  }

  /// 恢复到“适应屏幕”（缩放 1.0、位置归零）。
  void _resetZoom() {
    if (_scale <= _minScale + _zoomEpsilon &&
        _position == Offset.zero &&
        !_zoomSuspended) {
      return;
    }
    setState(() {
      _scale = _minScale;
      _position = Offset.zero;
      _edgeOverflow = 0.0;
    });
    _syncAutoPlayWithZoom();
  }

  /// 让自动播放与缩放状态保持一致：
  /// · 放大时暂停自动播放（避免用户正在看细节时被切走），并记录“因放大而暂停”；
  /// · 缩回原尺寸后，若暂停是放大引起的，自动恢复播放。
  void _syncAutoPlayWithZoom() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    if (_isZoomed) {
      if (slideProvider.isPlaying) {
        _zoomSuspended = true;
        _autoPlayTimer?.cancel();
      }
    } else if (_zoomSuspended) {
      _zoomSuspended = false;
      _startAutoPlay();
    }
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

    // 每次手势开始都重置边缘溢出量：它只在“单指·已放大”的拖拽过程中重新累积，
    // 否则双指捏合时的焦点位移会被误当成“继续向边缘拖拽”。
    _edgeOverflow = 0.0;
    _gesturePinched = false;
    // 手势开始时基于当前缩放重新夹紧，保证起点合法
    _position = _clampCurrent(
      Provider.of<SettingsProvider>(context, listen: false),
    );
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

    // 1) 缩放：以手势焦点为锚点，使焦点下的像素在缩放前后保持不动
    final newScale = (_startScale * details.scale).clamp(_minScale, _maxScale);
    final ratio = _startScale == 0 ? 1.0 : newScale / _startScale;

    // 2) 平移：
    //    - 缩放带来的分量用 ratio 推导（锚点=焦点）
    //    - 指尖自身的位移（focal - _startFocal）直接叠加，
    //      这样单指拖动时 details.scale 恒为 1.0、ratio 为 1，
    //      平移量恰好等于手指位移，不会出现“拖动被缩放放大”的漂移。
    final drag = focal - _startFocal;
    final position = _startPosition * ratio + focal - _startFocal * ratio;

    // 记录本次手势是否真的做过捏合，供松手时区分滑动与缩放
    if ((details.scale - 1.0).abs() >= 0.02) _gesturePinched = true;

    final clamped = _clamp(position, settings, newScale);
    setState(() {
      _scale = newScale;
      _position = clamped;
    });
    // 手势过程中就同步自动播放状态，让工具栏图标即时反映“因放大而暂停”
    _syncAutoPlayWithZoom();

    // 3) 单指拖拽且已放大时，记录“顶到边缘后继续往外推”的溢出量。
    //    这里只记录、不切图，真正的切换判断推迟到松开左键时（见 _handleScaleEnd），
    //    避免图片刚碰到边缘就被切走。
    //    用 details.scale 是否恒为 1.0 来判断“本次没有捏合意图”，
    //    与双指缩放区分开，避免捏合时焦点位移被当成向边缘拖拽。
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
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    // 注意：这些标志必须在 setState 重置之前读出来
    final edgeOverflow = _edgeOverflow; // 松手时仍顶在边缘的溢出量
    final wasPinching = _gesturePinched;
    final wasZoomed = _isZoomed;

    setState(() {
      if (_scale <= _minScale + _zoomEpsilon) {
        _scale = _minScale;
        _position = Offset.zero;
      } else {
        // 手势结束时再夹紧一次，防止旋转或尺寸变化后残留越界
        _position = _clampCurrent(settings);
      }
      _edgeOverflow = 0.0;
      _gesturePinched = false;
    });

    // 正在放大查看细节时不要自动切走，缩回原尺寸后再恢复自动播放
    if (_isZoomed) {
      // 松手时仍顶在左右边缘、且向外推超过阈值 → 切换上一张/下一张。
      // 拖拽过程中不切图，统一在松手这一刻判断，避免刚碰到边缘就被切走。
      if (edgeOverflow.abs() >= _edgeSwitchThreshold) {
        if (edgeOverflow > 0) {
          // 顶在右侧边缘继续右推 → 上一张
          _prevImage();
        } else {
          // 顶在左侧边缘继续左推 → 下一张
          _nextImage(manual: true);
        }
        return;
      }

      final slideProvider = Provider.of<SlideProvider>(context, listen: false);
      // 记录“因放大而暂停”，缩回原尺寸后据此自动恢复（不覆盖用户的主动暂停）
      _zoomSuspended = slideProvider.isPlaying;
      _autoPlayTimer?.cancel();
      return;
    }
    if (wasZoomed) {
      _zoomSuspended = false;
      _startAutoPlay();
      // 刚缩回原尺寸的这一次松手不再顺带切图，避免缩小时误翻页
      return;
    }

    // 以下情况不按速度切图：
    //  · 本次手势是捏合缩放（缩回时的焦点速度不具备翻页意图）
    if (wasPinching) return;

    // 未放大：按松手速度左右切换图片（等价于原来的横向拖拽手势）
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.dx.abs() <= velocity.dy.abs()) return; // 仅横向甩动才切图
    if (velocity.dx > _swipeVelocityThreshold) {
      _prevImage();
    } else if (velocity.dx < -_swipeVelocityThreshold) {
      _nextImage(manual: true);
    }
  }

  /// 为当前图片建立图片流监听，取得原始像素尺寸以计算平移边界
  void _updateIntrinsicSize(int index, String path) {
    if (_intrinsicSizeForIndex == index && _intrinsicSize != null) return;
    if (_intrinsicSizeForIndex == index) return; // 已发起过请求，等待回调

    _intrinsicSizeForIndex = index;
    _intrinsicSize = null;
    _detachIntrinsicSizeListener();

    // 关键：使用与 Image.file 完全相同的 provider（字节相同 → 缓存键相同），
    // 因此这里不会产生额外解码，只是复用已有的 ImageCache 条目。
    final provider = FileImage(File(path));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        // 监听器收到 ImageInfo 后由自己负责释放，否则每次切图都会泄漏一份解码位图
        info.dispose();
        if (!mounted || _intrinsicSizeForIndex != index) return;

        void applyIntrinsicSize() {
          if (!mounted || _intrinsicSizeForIndex != index) return;
          setState(() {
            _intrinsicSize = size;
            // 尺寸拿到后按真实比例重新夹紧位置
            _position = _clampCurrent(
              Provider.of<SettingsProvider>(context, listen: false),
            );
            // 方向相关的自动旋转依赖图片尺寸，尺寸就绪后需要重算一次
            _updateOrientationRotation(
              Provider.of<SlideProvider>(context, listen: false),
              Provider.of<SettingsProvider>(context, listen: false),
            );
          });
        }

        // 同步回调只可能在 addListener 时发生，而 _updateIntrinsicSize 是在 build 中调用的
        // （图片已在缓存时即命中此路径）。此时直接 setState 会抛出
        // “setState() called during build”，而该异常会被 ImageStreamCompleter 捕获后
        // 广播给同一图片流上的所有监听者，导致同源的 Image 误判为加载失败并显示“图片加载失败”。
        // 因此这里把状态更新推迟到当前帧结束之后。
        if (synchronousCall) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => applyIntrinsicSize(),
          );
        } else {
          applyIntrinsicSize();
        }
      },
      onError: (error, stackTrace) {
        // 尺寸获取失败时保持未知，平移边界退化为“不可平移”
      },
    );
    _intrinsicListener = listener;

    final stream = provider.resolve(createLocalImageConfiguration(context));
    _intrinsicStream = stream;
    stream.addListener(listener);
  }

  void _detachIntrinsicSizeListener() {
    if (_intrinsicStream != null && _intrinsicListener != null) {
      _intrinsicStream!.removeListener(_intrinsicListener!);
    }
    _intrinsicStream = null;
    _intrinsicListener = null;
  }

  void _rotateImage() {
    setState(() {
      // 累加 90°；渲染时按整数圈数交给 RotatedBox，避免浮点误差累积。
      _rotation += math.pi / 2;
      // 旋转后图片占据的屏幕区域变了，原平移量可能已经越界
      _position = _clampCurrent(
        Provider.of<SettingsProvider>(context, listen: false),
      );
    });
  }

  /// 向左旋转 90°（与 [_rotateImage] 方向相反）
  void _rotateLeftImage() {
    setState(() {
      _rotation -= math.pi / 2;
      _position = _clampCurrent(
        Provider.of<SettingsProvider>(context, listen: false),
      );
    });
  }

  /// 退出播放：停止自动播放、暂停播放并返回主界面
  void _exitPlayback() {
    final slideProvider = Provider.of<SlideProvider>(context, listen: false);
    // 停止自动播放定时器
    _autoPlayTimer?.cancel();
    // 如果正在播放，暂停播放
    if (slideProvider.isPlaying) {
      slideProvider.stopPlay();
    }
    // 返回主界面
    Navigator.pop(context);
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
          _prevImage();
          return true;
        case LogicalKeyboardKey.arrowRight:
          _nextImage(manual: true);
          return true;
        case LogicalKeyboardKey.arrowUp:
          // 以视口中心为锚点放大
          _zoomAt(_viewportCenter, _zoomStep);
          return true;
        case LogicalKeyboardKey.arrowDown:
          _zoomAt(_viewportCenter, 1 / _zoomStep);
          return true;
        case LogicalKeyboardKey.escape:
          // ESC 一次直接退出播放；全屏状态在页面销毁时一并恢复，
          // 全屏切换统一交给 F11（ESC 不再负责退出全屏）
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
          _rotateImage();
          return true;
        case LogicalKeyboardKey.keyL:
          _rotateLeftImage();
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
      final switchImage = modifierPressed
          ? !settings.wheelSwitchImage
          : settings.wheelSwitchImage;
      if (switchImage) {
        // 滚轮切换图片（不触发工具栏显示）
        if (event.scrollDelta.dy > 0) {
          _nextImage(manual: true);
        } else if (event.scrollDelta.dy < 0) {
          _prevImage();
        }
      } else {
        // 滚轮缩放图片：乘法步长 + 以光标为中心
        final factor = event.scrollDelta.dy > 0 ? 1 / _zoomStep : _zoomStep;
        _zoomAt(event.localPosition, factor);
      }
    } else if (event is PointerScaleEvent) {
      // 触控板双指捏合：按事件给出的倍率以触点为中心缩放
      _zoomAt(event.localPosition, event.scale);
    }
  }

  /// 右键呼出小菜单：放大 / 缩小 / 适应屏幕 / 旋转。
  Future<void> _showImageContextMenu(Offset globalPosition) async {
    final l10n = AppLocalizations.of(context);
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    // 菜单落在光标处
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlayBox.size,
    );
    // 缩放锚点需要相对视口的局部坐标
    final gestureBox =
        _gestureKey.currentContext?.findRenderObject() as RenderBox?;
    final localPosition = gestureBox != null
        ? gestureBox.globalToLocal(globalPosition)
        : _viewportCenter;

    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(value: 'zoomIn', child: Text(l10n.zoomIn)),
        PopupMenuItem<String>(value: 'zoomOut', child: Text(l10n.zoomOut)),
        PopupMenuItem<String>(value: 'fit', child: Text(l10n.fitScreen)),
        PopupMenuItem<String>(value: 'rotate', child: Text(l10n.rotate)),
      ],
    );
    if (!mounted || selected == null) return;

    switch (selected) {
      case 'zoomIn':
        _zoomAt(localPosition, _zoomStep);
        break;
      case 'zoomOut':
        _zoomAt(localPosition, 1 / _zoomStep);
        break;
      case 'fit':
        _resetZoom();
        break;
      case 'rotate':
        _rotateImage();
        break;
    }
  }

  /// 从缓存取文件大小文本；未缓存时返回占位符并触发异步加载。
  ///
  /// 切勿在 build 中直接读盘/解码，否则每次重建都会阻塞 UI 线程。
  String _fileSizeLabel(String path) {
    final cached = _fileSizeCache[path];
    if (cached != null) return cached;
    unawaited(_loadImageMeta(path));
    return '…';
  }

  /// 从缓存取分辨率文本；未缓存时返回占位符并触发异步加载。
  String _resolutionLabel(String path) {
    final cached = _resolutionCache[path];
    if (cached != null) return cached;
    unawaited(_loadImageMeta(path));
    return '…';
  }

  /// 只在磁盘上读取一次文件大小与图片分辨率，结果缓存起来。
  ///
  /// 解码放在后台 isolate（[compute]）中执行，避免阻塞手势帧。
  Future<void> _loadImageMeta(String path) async {
    if (_metaLoading.contains(path)) return;
    if (_fileSizeCache.containsKey(path) &&
        _resolutionCache.containsKey(path)) {
      return;
    }
    _metaLoading.add(path);
    final unknownText = AppLocalizations.of(context).unknown;
    try {
      final file = File(path);
      final sizeText = await _formatFileSize(file, unknownText);
      final resolutionText = await _decodeResolution(file, unknownText);
      if (!mounted) return;
      setState(() {
        _fileSizeCache[path] = sizeText;
        _resolutionCache[path] = resolutionText;
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

  static Future<String> _decodeResolution(File file, String unknownText) async {
    try {
      final bytes = await file.readAsBytes();
      final size = await compute(_decodeImageSize, bytes);
      if (size == null) return unknownText;
      return '${size.width} x ${size.height}';
    } catch (_) {
      return unknownText;
    }
  }

  /// 根据图片方向设置，更新自动旋转角度
  ///
  /// 依赖 [_intrinsicSize]（由图片流回调异步填充），不再同步解码文件。
  void _updateOrientationRotation(
    SlideProvider slideProvider,
    SettingsProvider settings,
  ) {
    if (slideProvider.images.isEmpty) return;

    final imagePath = slideProvider.images[slideProvider.currentIndex].path;

    switch (settings.imageOrientation) {
      case ImageOrientation.landscape:
        // 强制横屏：如果图片是竖屏的，旋转90°
        _autoRotation = _isPortraitImage() ? math.pi / 2 : 0.0;
        break;
      case ImageOrientation.portrait:
        // 强制竖屏：如果图片是横屏的，旋转90°
        _autoRotation = _isLandscapeImage() ? math.pi / 2 : 0.0;
        break;
      case ImageOrientation.followSystem:
        _autoRotation = 0.0;
        break;
      case ImageOrientation.followImage:
        // 跟随图片：让图片的长边对齐屏幕长边
        _autoRotation = _getRotationToMatchScreen(imagePath);
        break;
    }
  }

  /// 计算让图片长边对齐屏幕长边所需的旋转角度。
  ///
  /// 优先使用已缓存的原始尺寸（与缩放共用同一份数据），
  /// 避免在此处同步读盘+解码。
  double _getRotationToMatchScreen(String path) {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null || _intrinsicSizeForIndex != _lastProcessedIndex) {
      // 尺寸尚未就绪：先按不旋转处理，_updateIntrinsicSize 回调里会重新计算
      return 0.0;
    }

    final size = MediaQuery.of(context).size;
    final isScreenLandscape = size.width >= size.height;
    final isImageLandscape = intrinsic.width >= intrinsic.height;

    // 如果图片方向和屏幕方向不一致，旋转 90° 使长边对齐
    if (isScreenLandscape != isImageLandscape) {
      return math.pi / 2;
    }
    return 0.0;
  }

  bool _isPortraitImage() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.height > intrinsic.width;
  }

  bool _isLandscapeImage() {
    final intrinsic = _intrinsicSize;
    if (intrinsic == null) return false;
    return intrinsic.width > intrinsic.height;
  }

  /// 根据设置锁定屏幕方向（移动端使用）
  void _applyScreenOrientation(SettingsProvider settings) {
    switch (settings.imageOrientation) {
      case ImageOrientation.landscape:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case ImageOrientation.portrait:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
      case ImageOrientation.followSystem:
      case ImageOrientation.followImage:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
    }
  }

  Widget _buildTransitionAnimation(Widget child, int index) {
    final settings = Provider.of<SettingsProvider>(context);

    switch (settings.transitionAnimation) {
      case TransitionAnimation.none:
        return child;
      case TransitionAnimation.fade:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: child,
        );
      case TransitionAnimation.slideLeft:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
      case TransitionAnimation.slideUp:
        return AnimatedSwitcher(
          duration: Duration(
            milliseconds: (settings.animationDuration * 1000).toInt(),
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: child,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SlideProvider, SettingsProvider>(
      builder: (context, slideProvider, settings, child) {
        // 检测设置变更并即时应用运行时效果（轮播间隔、方向、自动隐藏等）
        _applySettingsToPlayback(settings);

        if (slideProvider.images.isEmpty) {
          return Scaffold(
            backgroundColor: settings.background,
            body: Center(child: Text(AppLocalizations.of(context).noImages)),
          );
        }

        // 图片索引变化时更新方向旋转
        if (slideProvider.currentIndex != _lastProcessedIndex) {
          _lastProcessedIndex = slideProvider.currentIndex;
          _updateOrientationRotation(slideProvider, settings);
          _applyScreenOrientation(settings);
          // 同步当前图片的原始尺寸，用于计算缩放后的平移边界
          _updateIntrinsicSize(
            slideProvider.currentIndex,
            slideProvider.images[slideProvider.currentIndex].path,
          );
        }

        return Scaffold(
          backgroundColor: settings.background,
          body: Focus(
            autofocus: true,
            child: Listener(
              onPointerSignal: _handleScroll,
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
                // 图片以 Stack 铺满整个 body，因此用它的约束尺寸作为
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
                    // 统一交给缩放识别器：
                    //   · 未放大 → 松手时按速度切图（见 _handleScaleEnd）
                    //   · 放大后 → 单指拖动平移 + 靠泊后继续推出切图
                    onScaleStart: _handleScaleStart,
                    onScaleUpdate: _handleScaleUpdate,
                    onScaleEnd: _handleScaleEnd,
                    onSecondaryTapUp: (details) =>
                        _showImageContextMenu(details.globalPosition),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildTransitionAnimation(
                          Transform(
                            key: ValueKey(slideProvider.currentIndex),
                            alignment: Alignment.center,
                            // 顺序很重要：Matrix4 的方法是在右侧相乘，
                            // 因此 M = T · S。平移在最外层，_position 才是纯屏幕
                            // 像素，与 [_clamp] 的边界计算保持一致；
                            // 若把 translate 写在最后（M = S · T），位移会被缩放放大。
                            //
                            // 旋转不放在这里：Transform 只在绘制阶段旋转，会把
                            // 「已按视口适配好的整块区域」连黑边一起转过来，导致
                            // contain 下旋转 90° 后四周都是黑边、短边填不满。
                            // 旋转改由下面的 RotatedBox 在布局阶段完成。
                            transform: Matrix4.identity()
                              ..translateByVector3(
                                vector.Vector3(_position.dx, _position.dy, 0),
                              )
                              ..scaleByVector3(
                                vector.Vector3(_scale, _scale, _scale),
                              ),
                            child: SizedBox.expand(
                              child: RotatedBox(
                                // 布局阶段旋转：RotatedBox 会把父级约束沿对角翻转
                                // 后再交给图片适配，于是 contain 的短边能真正贴满
                                // 屏幕短边（与 [_displayBaseSize] 的算法一致）。
                                quarterTurns: _quarterTurns,
                                child: Image.file(
                                  File(
                                    slideProvider
                                        .images[slideProvider.currentIndex]
                                        .path,
                                  ),
                                  fit: settings.boxFit,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Center(
                                        child: Text(
                                          AppLocalizations.of(
                                            context,
                                          ).imageLoadFailed,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                          slideProvider.currentIndex,
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
                                '${slideProvider.currentIndex + 1} / ${slideProvider.images.length}',
                                style: const TextStyle(fontSize: 16),
                              ),
                              leading: Tooltip(
                                message: AppLocalizations.of(context).back,
                                child: IconButton(
                                  icon: const Icon(Icons.arrow_back),
                                  onPressed: () {
                                    // 如果当前是全屏状态，先退出全屏再返回
                                    if (_isFullscreen) {
                                      _exitFullscreen();
                                      final navigator = Navigator.of(context);
                                      // 延迟一小段时间让窗口状态稳定后再返回
                                      Future.delayed(
                                        const Duration(milliseconds: 200),
                                        () {
                                          if (mounted) navigator.pop();
                                        },
                                      );
                                    } else {
                                      Navigator.pop(context);
                                    }
                                  },
                                ),
                              ),
                              actions: [
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
                                Tooltip(
                                  message:
                                      settings.deleteAction ==
                                          DeleteAction.exclude
                                      ? AppLocalizations.of(
                                          context,
                                        ).excludeFromPlay
                                      : AppLocalizations.of(
                                          context,
                                        ).deleteFileLabel,
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
                                  message: AppLocalizations.of(context).rotate,
                                  child: IconButton(
                                    icon: const Icon(Icons.rotate_right),
                                    onPressed: _rotateImage,
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
                              ],
                            ),
                          ),
                        if (_showControls)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.5),
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  if (settings.showImageInfo && _showInfo)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              slideProvider
                                                  .images[slideProvider
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
                                                    .images[slideProvider
                                                        .currentIndex]
                                                    .path,
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
                                                    .images[slideProvider
                                                        .currentIndex]
                                                    .path,
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
                                  Row(
                                    key: _bottomControlsKey,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.skip_previous,
                                          size: 36,
                                        ),
                                        color: Colors.white,
                                        onPressed: () {
                                          _prevImage();
                                          _showControlsTemporarily();
                                        },
                                      ),
                                      const SizedBox(width: 32),
                                      IconButton(
                                        icon: Icon(
                                          // 放大查看时自动播放会被暂停，
                                          // 此处应显示“暂停状态”的播放图标而非暂停图标
                                          slideProvider.isPlaying &&
                                                  !_zoomSuspended
                                              ? Icons.pause_circle
                                              : Icons.play_circle,
                                          size: 64,
                                        ),
                                        color: Colors.white,
                                        onPressed: _togglePlay,
                                      ),
                                      const SizedBox(width: 32),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.skip_next,
                                          size: 36,
                                        ),
                                        color: Colors.white,
                                        onPressed: () {
                                          _nextImage(manual: true);
                                          _showControlsTemporarily();
                                        },
                                      ),
                                    ],
                                  ),
                                ],
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
    );
  }
}
