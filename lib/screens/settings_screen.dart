import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// 宽度达到该值时分左右两栏显示，否则保持单栏。
  static const double _twoColumnBreakpoint = 900;

  /// 是否为手机端。
  ///
  /// 手机端应用本身就是独占全屏的，窗口化的「全屏」概念不存在，
  /// 因此「播放时自动全屏」这类桌面专属选项在手机端不展示。
  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).settingsTitle),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) =>
            _buildResponsiveBody(context, constraints, _sectionGroups(context)),
      ),
    );
  }

  /// 设置页的所有分组。
  ///
  /// [weight] 是各分组高度的粗略估算，仅用于宽屏分栏时把分组均衡地分到各列。
  List<_SettingsGroup> _sectionGroups(BuildContext context) {
    return [
      // 语言设置
      _SettingsGroup(
        weight: 2,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).languageLabel),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => _buildDropdownSetting(
              context,
              AppLocalizations.of(context).languageLabel,
              [
                (AppLocalizations.of(context).systemLang, 0),
                ('简体中文', 1),
                ('繁體中文', 3),
                ('English', 2),
              ],
              settings.languageIndex,
              (value) => settings.setLanguageIndex(value),
            ),
          ),
        ],
      ),
      // 播放基础设置
      _SettingsGroup(
        weight: 5,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).playSettings),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildIntervalSetting(
                  context,
                  AppLocalizations.of(context).interval,
                  settings.presetInterval,
                  settings.customInterval,
                  settings.useCustomInterval,
                  (value) => settings.setPresetInterval(value),
                  (value) => settings.setCustomInterval(value),
                  (value) => settings.setUseCustomInterval(value),
                ),
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).playOrderMode,
                  [
                    (
                      AppLocalizations.of(context).sequential,
                      PlayOrder.sequential,
                    ),
                    (
                      AppLocalizations.of(context).playReverse,
                      PlayOrder.reverseSequential,
                    ),
                    (
                      AppLocalizations.of(context).newestFirst,
                      PlayOrder.newestFirst,
                    ),
                    (
                      AppLocalizations.of(context).oldestFirst,
                      PlayOrder.oldestFirst,
                    ),
                    (AppLocalizations.of(context).randomPlay, PlayOrder.random),
                    (
                      AppLocalizations.of(context).newPreferred,
                      PlayOrder.newPreferred,
                    ),
                  ],
                  settings.playOrder,
                  (value) => settings.setPlayOrder(value),
                ),
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).loopPlay,
                  AppLocalizations.of(context).loopPlayDesc,
                  settings.loopPlay,
                  (value) => settings.setLoopPlay(value),
                ),
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).autoPlay,
                  AppLocalizations.of(context).autoPlayDesc,
                  settings.autoPlay,
                  (value) => settings.setAutoPlay(value),
                ),
                // 手机端本就独占全屏，该选项不展示
                if (!_isMobile)
                  _buildSwitchSetting(
                    context,
                    AppLocalizations.of(context).startFullscreen,
                    '',
                    settings.startFullscreen,
                    (value) => settings.setStartFullscreen(value),
                  ),
              ],
            ),
          ),
        ],
      ),
      // 图片显示设置
      _SettingsGroup(
        weight: 4,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).imageDisplay),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).fitMode,
                  [
                    (
                      AppLocalizations.of(context).contain,
                      ImageFitMode.contain,
                    ),
                    (AppLocalizations.of(context).cover, ImageFitMode.cover),
                    (
                      AppLocalizations.of(context).original,
                      ImageFitMode.original,
                    ),
                  ],
                  settings.imageFitMode,
                  (value) => settings.setImageFitMode(value),
                ),
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).backgroundColorLabel,
                  [
                    (AppLocalizations.of(context).black, BackgroundColor.black),
                    (
                      AppLocalizations.of(context).darkGray,
                      BackgroundColor.darkGray,
                    ),
                    (AppLocalizations.of(context).white, BackgroundColor.white),
                  ],
                  settings.backgroundColor,
                  (value) => settings.setBackgroundColor(value),
                ),
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).orientationLabel,
                  [
                    (
                      AppLocalizations.of(context).landscape,
                      ImageOrientation.landscape,
                    ),
                    (
                      AppLocalizations.of(context).portrait,
                      ImageOrientation.portrait,
                    ),
                    (
                      AppLocalizations.of(context).followSystem,
                      ImageOrientation.followSystem,
                    ),
                    (
                      AppLocalizations.of(context).followImage,
                      ImageOrientation.followImage,
                    ),
                  ],
                  settings.imageOrientation,
                  (value) => settings.setImageOrientation(value),
                ),
              ],
            ),
          ),
        ],
      ),
      // 切换动画
      _SettingsGroup(
        weight: 3,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).transitionAnimation),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).transitionAnimation,
                  [
                    (
                      AppLocalizations.of(context).none,
                      TransitionAnimation.none,
                    ),
                    (
                      AppLocalizations.of(context).fade,
                      TransitionAnimation.fade,
                    ),
                    (
                      AppLocalizations.of(context).slideLeft,
                      TransitionAnimation.slideLeft,
                    ),
                    (
                      AppLocalizations.of(context).slideUp,
                      TransitionAnimation.slideUp,
                    ),
                  ],
                  settings.transitionAnimation,
                  (value) => settings.setTransitionAnimation(value),
                ),
                _buildSliderSetting(
                  context,
                  AppLocalizations.of(context).animDuration,
                  '${settings.animationDuration.toStringAsFixed(1)}${AppLocalizations.of(context).second}',
                  settings.animationDuration,
                  0.1,
                  1.0,
                  0.1,
                  (value) => settings.setAnimationDuration(value),
                ),
              ],
            ),
          ),
        ],
      ),
      // 工具栏
      _SettingsGroup(
        weight: 5,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).windowFullscreen),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).hideToolbarLabel,
                  AppLocalizations.of(context).hideToolbarDesc,
                  settings.hideToolbar,
                  (value) => settings.setHideToolbar(value),
                ),
                _buildSliderSetting(
                  context,
                  AppLocalizations.of(context).hideDelay,
                  '${settings.controlsHideDelay}${AppLocalizations.of(context).second}',
                  settings.controlsHideDelay.toDouble(),
                  1,
                  15,
                  1,
                  (value) => settings.setControlsHideDelay(value.toInt()),
                ),
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).keepOnPause,
                  AppLocalizations.of(context).keepOnPauseDesc,
                  settings.keepControlsOnPause,
                  (value) => settings.setKeepControlsOnPause(value),
                ),
              ],
            ),
          ),
        ],
      ),
      // 文件与目录相关
      _SettingsGroup(
        weight: 2,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).filesAndDirs),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).recursiveScan,
                  AppLocalizations.of(context).recursiveScanDesc,
                  settings.recursiveScan,
                  (value) => settings.setRecursiveScan(value),
                ),
              ],
            ),
          ),
        ],
      ),
      // 信息显示设置
      _SettingsGroup(
        weight: 4,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).infoDisplay),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).showImageInfo,
                  AppLocalizations.of(context).showImageInfoDesc,
                  settings.showImageInfo,
                  (value) => settings.setShowImageInfo(value),
                ),
                _buildSwitchSetting(
                  context,
                  AppLocalizations.of(context).infoAutoHideLabel,
                  AppLocalizations.of(context).infoAutoHideDesc,
                  settings.infoAutoHide,
                  (value) => settings.setInfoAutoHide(value),
                ),
                _buildSliderSetting(
                  context,
                  AppLocalizations.of(context).infoHideDelay,
                  '${settings.infoHideDelay}${AppLocalizations.of(context).second}',
                  settings.infoHideDelay.toDouble(),
                  1,
                  15,
                  1,
                  (value) => settings.setInfoHideDelay(value.toInt()),
                ),
              ],
            ),
          ),
        ],
      ),
      // 快捷键与控制
      _SettingsGroup(
        weight: 4,
        widgets: [
          _buildSectionTitle(AppLocalizations.of(context).controlsLabel),
          Consumer<SettingsProvider>(
            builder: (context, settings, child) => Column(
              children: [
                // 手机端没有滚轮，该选项不展示
                if (!_isMobile)
                  _buildDropdownSetting(
                    context,
                    AppLocalizations.of(context).wheelSwitch,
                    [
                      (AppLocalizations.of(context).wheelSwitchImage, true),
                      (AppLocalizations.of(context).wheelZoom, false),
                    ],
                    settings.wheelSwitchImage,
                    (value) => settings.setWheelSwitchImage(value),
                    // 说明修饰键滚轮执行的是与当前设置相反的行为
                    subtitle: settings.wheelSwitchImage
                        ? AppLocalizations.of(context).ctrlWheelZoomHint
                        : AppLocalizations.of(context).ctrlWheelSwitchHint,
                  ),
                _buildDropdownSetting(
                  context,
                  AppLocalizations.of(context).deleteBehavior,
                  [
                    (
                      AppLocalizations.of(context).excludeFromPlay,
                      DeleteAction.exclude,
                    ),
                    (
                      AppLocalizations.of(context).deleteFile,
                      DeleteAction.delete,
                    ),
                  ],
                  settings.deleteAction,
                  (value) => settings.setDeleteAction(value),
                  // 说明修饰键 + Del 执行的是与当前设置相反的行为；
                  // 手机端没有 Ctrl 键，不显示该提示
                  subtitle: _isMobile
                      ? ''
                      : (settings.deleteAction == DeleteAction.exclude
                            ? AppLocalizations.of(context).ctrlDelDeleteHint
                            : AppLocalizations.of(context).ctrlDelExcludeHint),
                ),
                // 内置快捷键说明全部是键盘按键，手机端不展示
                if (!_isMobile) _buildShortcutInfo(context),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  /// 根据可用宽度决定单栏还是双栏布局。
  ///
  /// 两种布局都只有一个 [ListView]：宽度足够时把左右两栏放进同一个滚动列表里，
  /// 两栏共用一个滚动位置（同时滚动），而不是各自独立滚动。
  Widget _buildResponsiveBody(
    BuildContext context,
    BoxConstraints constraints,
    List<_SettingsGroup> groups,
  ) {
    const padding = EdgeInsets.all(16);
    final availableWidth = constraints.maxWidth - padding.horizontal;
    // 宽度不确定（例如无界约束）时按单栏处理，避免误判。
    final isTwoColumn =
        constraints.maxWidth.isFinite &&
        availableWidth >= SettingsScreen._twoColumnBreakpoint;

    if (!isTwoColumn) {
      return ListView(
        padding: padding,
        children: _interleaveGroupsWithSpacing(groups),
      );
    }

    // 按估算高度把分组均衡地分到左右两栏（顺序保持不变）。
    final columns = _distributeGroups(groups, 2);
    // IntrinsicHeight 为两栏提供有界高度，让分隔线能铺满整列；
    // 两栏同处一个 ListView 内，滚动时一起移动。
    return ListView(
      padding: padding,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns.length; i++) ...[
                if (i > 0)
                  const VerticalDivider(width: 32, color: Colors.white12),
                Expanded(
                  child: Column(
                    key: ValueKey('settings-column-$i'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _interleaveGroupsWithSpacing(columns[i]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 把分组铺平成 widget 列表，并在组与组之间插入间距。
  ///
  /// 单栏与双栏都复用这套排布，因此共用同一个 [ListView] 的滚动位置，
  /// 切换窗口宽度时不会出现两套滚动状态。
  List<Widget> _interleaveGroupsWithSpacing(List<_SettingsGroup> groups) {
    return [
      for (var i = 0; i < groups.length; i++) ...[
        if (i > 0) const SizedBox(height: 24),
        ...groups[i].widgets,
      ],
    ];
  }

  /// 把分组按估算高度均衡地分配到 [count] 列（保持原有顺序）。
  ///
  /// 每次把下一个分组放入当前最矮的一列，尽量让各列高度接近。
  List<List<_SettingsGroup>> _distributeGroups(
    List<_SettingsGroup> groups,
    int count,
  ) {
    final columns = List.generate(count, (_) => <_SettingsGroup>[]);
    final heights = List.filled(count, 0);
    for (final group in groups) {
      var target = 0;
      for (var i = 1; i < count; i++) {
        if (heights[i] < heights[target]) target = i;
      }
      columns[target].add(group);
      heights[target] += group.weight;
    }
    return columns;
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.blueAccent,
        ),
      ),
    );
  }

  Widget _buildSwitchSetting(
    BuildContext context,
    String title,
    String subtitle,
    bool value,
    void Function(bool) onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyLarge),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          // 固定宽度容器，开关右边缘与下拉按钮右边缘对齐
          SizedBox(
            width: 100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: const Color(0xFFe94560),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderSetting(
    BuildContext context,
    String title,
    String label,
    double value,
    double min,
    double max,
    double division,
    void Function(double) onChanged,
  ) {
    return ListTile(
      title: Text(title),
      subtitle: Slider(
        value: value,
        min: min,
        max: max,
        divisions: ((max - min) / division).round(),
        label: label,
        onChanged: onChanged,
        activeColor: const Color(0xFFe94560),
      ),
      trailing: Text(label, style: const TextStyle(color: Colors.grey)),
    );
  }

  Widget _buildIntervalSetting(
    BuildContext context,
    String title,
    int presetInterval,
    int customInterval,
    bool useCustomInterval,
    void Function(int) onChanged,
    void Function(int) onCustomChanged,
    void Function(bool) onUseCustomChanged,
  ) {
    final l10n = AppLocalizations.of(context);
    // 间隔选项（毫秒）
    const intervals = [
      1000,
      2000,
      3000,
      4000,
      5000,
      6000,
      7000,
      8000,
      9000,
      10000,
      15000,
      20000,
      30000,
      45000,
      60000,
      120000,
      180000,
      300000,
      600000,
    ];
    // 对应的显示文字
    String intervalLabel(int ms) {
      if (ms < 60000) return '${ms ~/ 1000}${l10n.second}';
      if (ms < 3600000) return '${ms ~/ 60000}${l10n.minute}';
      return '${ms ~/ 60000}${l10n.minute}';
    }

    // 档位值未命中预设刻度时，滑块落在最接近的档位上（超出最大档则落在末档）
    var sliderIndex = intervals.indexWhere((ms) => ms >= presetInterval);
    if (sliderIndex < 0) sliderIndex = intervals.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              Text(
                intervalLabel(intervals[sliderIndex]),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
          Slider(
            value: sliderIndex.toDouble(),
            min: 0,
            max: (intervals.length - 1).toDouble(),
            divisions: intervals.length - 1,
            label: intervalLabel(intervals[sliderIndex]),
            // 自定义开启时档位不生效，滑块仅保留原有位置
            onChanged: useCustomInterval
                ? null
                : (value) => onChanged(intervals[value.round()]),
            activeColor: const Color(0xFFe94560),
          ),
          // 自定义间隔输入（独立一行）
          const SizedBox(height: 12),
          Row(
            children: [
              // 左侧整组占满剩余宽度：标签后紧跟输入框与单位，多余空白落在开关之前
              Expanded(
                child: Row(
                  children: [
                    // 空间不足时优先收缩标签，避免整行溢出
                    Flexible(
                      child: Text(
                        l10n.customIntervalLabel,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 80,
                      height: 38,
                      child: _CustomInlineInput(
                        initialValue: customInterval ~/ 1000,
                        enabled: useCustomInterval,
                        onSubmit: (seconds) => onCustomChanged(seconds * 1000),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.second,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: useCustomInterval,
                onChanged: onUseCustomChanged,
                activeThumbColor: const Color(0xFFe94560),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownSetting<T>(
    BuildContext context,
    String title,
    List<(String, T)> options,
    T value,
    void Function(T) onChanged, {
    String subtitle = '',
  }) {
    final selectedLabel = options
        .firstWhere((o) => o.$2 == value, orElse: () => options.first)
        .$1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyLarge),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          PopupMenuButton<T>(
            initialValue: value,
            onSelected: onChanged,
            offset: const Offset(0, 40),
            itemBuilder: (context) => options.map((option) {
              final isSelected = value == option.$2;
              return PopupMenuItem<T>(
                value: option.$2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(option.$1),
                    if (isSelected) ...[
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.check,
                        size: 18,
                        color: Color(0xFFe94560),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0f3460),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    selectedLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, color: Colors.white70),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutInfo(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shortcuts = [
      (l10n.spaceKey, l10n.playPause),
      ('←', l10n.previous),
      ('→', l10n.next),
      ('↑', l10n.zoomIn),
      ('↓', l10n.zoomOut),
      ('R', l10n.rotateRight),
      ('L', l10n.rotateLeft),
      ('ESC', l10n.exitPlayback),
      ('F11', l10n.toggleFullscreen),
      ('Del', l10n.deleteImage),
    ];

    // 快捷键条目较多，均分到左右两列显示，避免面板过高
    final half = (shortcuts.length + 1) ~/ 2;
    final leftColumn = shortcuts.take(half).toList();
    final rightColumn = shortcuts.skip(half).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.keyboard, size: 20, color: Colors.blueAccent.shade200),
              const SizedBox(width: 8),
              Text(
                l10n.shortcutTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueAccent,
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final shortcut in leftColumn)
                      _buildShortcutRow(shortcut),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final shortcut in rightColumn)
                      _buildShortcutRow(shortcut),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单条快捷键：左侧按键标签 + 右侧说明文字。
  ///
  /// 说明文字用 [Expanded] 约束宽度，列较窄时自动换行而不是溢出。
  Widget _buildShortcutRow((String, String) shortcut) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              shortcut.$1,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                shortcut.$2,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置页中的一个分组（一个标题 + 若干选项控件）。
class _SettingsGroup {
  const _SettingsGroup({required this.widgets, required this.weight});

  /// 该分组包含的控件（标题与各选项）。
  final List<Widget> widgets;

  /// 分组高度的粗略估算，仅用于宽屏分栏时均衡各列高度。
  final int weight;
}

/// 换片时间设置里的自定义秒数输入组件
class _CustomInlineInput extends StatefulWidget {
  final int initialValue;
  final bool enabled;
  final void Function(int) onSubmit;

  const _CustomInlineInput({
    required this.initialValue,
    this.enabled = true,
    required this.onSubmit,
  });

  @override
  State<_CustomInlineInput> createState() => _CustomInlineInputState();
}

class _CustomInlineInputState extends State<_CustomInlineInput> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initialValue}');
  }

  @override
  void didUpdateWidget(covariant _CustomInlineInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _controller.text = '${widget.initialValue}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final seconds = int.tryParse(_controller.text);
    if (seconds != null && seconds > 1 && seconds < 65535) {
      widget.onSubmit(seconds);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: widget.enabled,
      keyboardType: TextInputType.number,
      style: TextStyle(
        fontSize: Theme.of(context).textTheme.bodyLarge?.fontSize,
        color: Colors.white,
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        filled: true,
        fillColor: Colors.black26,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFFe94560)),
        ),
      ),
      onSubmitted: (_) => _submit(),
    );
  }
}
