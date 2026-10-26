import 'dart:io';
import 'package:flutter/material.dart';

/// 语言选项索引
enum AppLanguage {
  system(0, '跟随系统', Locale('en', 'US')),
  zhCN(1, '简体中文', Locale('zh', 'CN')),
  en(2, 'English', Locale('en', 'US')),
  zhTW(3, '繁體中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));

  final int value;
  final String label;
  final Locale locale;
  const AppLanguage(this.value, this.label, this.locale);
}

/// 轻量级国际化支持（简体中文 / English / 繁體中文）
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  /// 语言代码
  String get languageCode => locale.languageCode;
  String get scriptCode => locale.scriptCode ?? '';

  /// 是否为简体中文
  bool get isZhCN => languageCode == 'zh' && scriptCode != 'Hant';

  /// 是否为繁体中文
  bool get isZhTW => languageCode == 'zh' && scriptCode == 'Hant';

  /// 是否为英文
  bool get isEn => languageCode == 'en';

  /// 根据固定语言索引创建实例
  static AppLocalizations fromIndex(int langIndex) {
    switch (langIndex) {
      case 1:
        return AppLocalizations(const Locale('zh', 'CN'));
      case 2:
        return AppLocalizations(const Locale('en', 'US'));
      case 3:
        return AppLocalizations(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        );
      default:
        return AppLocalizations(_systemLocale());
    }
  }

  /// 根据系统语言创建实例
  static AppLocalizations of(BuildContext context) {
    return AppLocalizations(Localizations.localeOf(context));
  }

  static Locale _systemLocale() {
    final loc = Platform.localeName;
    if (loc.startsWith('zh')) {
      if (loc.contains('TW') || loc.contains('HK') || loc.contains('MO')) {
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      }
      return const Locale('zh', 'CN');
    }
    return const Locale('en', 'US');
  }

  // ──────────── 翻译 ────────────

  String get appName => _t('SteamFlow', 'SteamFlow', 'SteamFlow');
  String get appTitle => 'SteamFlow';
  String get homeTitle => 'SteamFlow';

  // 首页
  String get startPlay => _t('开始播放', 'Start', '開始播放');
  String get selectAlbum => _t('选择相册', 'Albums', '選擇相冊');
  String get selectVideos => _t('选择视频', 'Videos', '選擇視頻');
  String get settings => _t('设置', 'Settings', '設置');
  String get scanning => _t('正在扫描视频...', 'Scanning...', '正在掃描視頻...');

  // 相册选择页
  String get selectAlbumTitle => _t('选择相册', 'Albums', '選擇相冊');
  String get addAlbum => _t('添加相册', 'Add Album', '添加相冊');
  String get addFolder => _t('添加文件夹', 'Add Folder', '添加文件夾');
  String get playFolder => _t('播放此文件夹', 'Play This Folder', '播放此資料夾');
  String get pleaseAddAlbum => _t('请添加相册', 'Add Albums', '請添加相冊');
  String get pleaseAddFolder => _t('请添加文件夹', 'Add Folders', '請添加文件夾');
  String get confirm => _t('确定', 'OK', '確定');
  String get cancel => _t('取消', 'Cancel', '取消');

  // 播放页
  String get noVideos => _t('没有视频', 'No Videos', '沒有視頻');
  String get videoLoadFailed => _t('视频加载失败', 'Load Failed', '視頻加載失敗');
  String get unknownDate => _t('未知日期', 'Unknown Date', '未知日期');

  // 设置页
  String get settingsTitle => _t('设置', 'Settings', '設置');
  String get languageLabel => _t('语言', 'Language', '語言');
  String get systemLang => _t('跟随系统', 'System', '跟隨系統');
  String get playOrderMode => _t('播放顺序', 'Play Order', '播放順序');
  String get playSettings => _t('播放设置', 'Playback', '播放設置');
  String get sequential => _t('顺序播放', 'Sequential', '順序播放');
  String get playReverse => _t('逆序播放', 'Reverse', '逆序播放');
  String get randomPlay => _t('随机播放', 'Random', '隨機播放');
  String get newestFirst => _t('由新到旧', 'Newest First', '由新到舊');
  String get oldestFirst => _t('由旧到新', 'Oldest First', '由舊到新');
  String get newPreferred => _t('新视频优先', 'New Preferred', '新視頻優先');
  String get resumePlayback => _t('接续播放', 'Resume Playback', '接續播放');
  String get resumePlaybackDesc => _t(
    '未播放完毕的视频下次进入时从何处开始播放',
    'Where an unfinished video starts next time',
    '未播放完畢的視頻下次進入時從何處開始播放',
  );
  String get resumePlaybackFromStart =>
      _t('从头播放', 'From Start', '從頭播放');
  String get loopPlay => _t('循环播放', 'Loop', '循環播放');
  String get loopPlayDesc =>
      _t('关闭：播完停止；开启：首尾循环', 'Off: stop at end; On: loop', '關閉：播完停止；開啟：首尾循環');
  String get volume => _t('音量', 'Volume', '音量');
  String get playbackSpeed => _t('播放速度', 'Playback Speed', '播放速度');
  String get singleLoop => _t('单一循环', 'Single Loop', '單一循環');
  String get autoPlay => _t('自动播放', 'Auto Play', '自動播放');
  String get autoPlayDesc =>
      _t('进入应用后立即开始播放', 'Start playback on launch', '進入應用後立即開始播放');
  String get minute => _t('分钟', 'min', '分鐘');
  String get toggleFullscreen => _t('全屏切换', 'Toggle Fullscreen', '全屏切換');
  String get videoDisplay => _t('视频显示', 'Display', '視頻顯示');
  String get fitMode => _t('填充模式', 'Fit Mode', '填充模式');
  String get contain => _t('适应窗口', 'Contain', '適應窗口');
  String get cover => _t('填满窗口', 'Cover', '填滿窗口');
  String get original => _t('原始大小', 'Original', '原始大小');
  String get backgroundColorLabel => _t('背景底色', 'Background', '背景底色');
  String get black => _t('黑色', 'Black', '黑色');
  String get darkGray => _t('深灰', 'Dark Gray', '深灰');
  String get white => _t('白色', 'White', '白色');
  String get orientationLabel => _t('屏幕方向', 'Orientation', '屏幕方向');
  String get landscape => _t('横屏', 'Landscape', '橫屏');
  String get portrait => _t('竖屏', 'Portrait', '豎屏');
  String get followSystem => _t('跟随系统', 'System', '跟隨係統');
  String get followVideo => _t('跟随视频', 'Follow Video', '跟隨視頻');
  String get windowFullscreen => _t('工具栏', 'Toolbar', '工具欄');
  String get startFullscreen => _t('播放时自动全屏', 'Auto Fullscreen', '播放時自動全屏');
  String get hideToolbarLabel => _t('自动隐藏工具栏', 'Hide Toolbar', '自動隱藏工具欄');
  String get hideToolbarDesc => _t(
    '一段时间无操作自动隐藏上下工具栏',
    'Auto-hide controls after idle',
    '一段時間無操作自動隱藏上下工具欄',
  );
  String get hideDelay => _t('隐藏延迟', 'Hide Delay', '隱藏延遲');
  String get keepOnPause => _t('暂停时保持工具栏', 'Keep on Pause', '暫停時保持工具欄');
  String get keepOnPauseDesc => _t(
    '暂停播放时不自动隐藏播放工具栏',
    'Keep controls visible when paused',
    '暫停播放時不自動隱藏播放工具欄',
  );
  String get filesAndDirs => _t('文件管理', 'File Management', '文件管理');
  String get recursiveScan => _t('包含子文件夹', 'Include Subfolders', '包含子文件夾');
  String get recursiveScanDesc => _t(
    '开启后连子文件夹里的视频一起播放',
    'Play videos from subfolders too',
    '開啟後連子文件夾裡的視頻一起播放',
  );
  String get browseLayout => _t('浏览格式', 'Browse Layout', '瀏覽格式');
  String get browseLayoutMasonry => _t('瀑布流', 'Masonry', '瀑布流');
  String get browseLayoutSquare => _t('正方形', 'Square', '正方形');
  String get browseLayoutLandscape4x3 =>
      _t('横屏 4:3', 'Landscape 4:3', '橫屏 4:3');
  String get browseLayoutLandscape16x9 =>
      _t('横屏 16:9', 'Landscape 16:9', '橫屏 16:9');
  String get browseLayoutPortrait3x4 => _t('竖屏 3:4', 'Portrait 3:4', '豎屏 3:4');
  String get browseLayoutPortrait9x16 =>
      _t('竖屏 9:16', 'Portrait 9:16', '豎屏 9:16');
  String get fileListInfo => _t('文件列表信息', 'File List Info', '文件列表信息');
  String get fileListInfoDesc => _t(
    '选中项显示在卡片下方',
    'Show the selected field under each grid card',
    '選中項顯示在卡片下方',
  );
  String get fileListInfoNone => _t('不显示', 'None', '不顯示');
  String get fileListInfoName => _t('文件名', 'Name', '文件名');
  String get fileListInfoNameDateSize =>
      _t('文件名+日期+大小', 'Name + Date + Size', '文件名+日期+大小');
  String get showVideoInfo => _t('视频信息显示', 'Show Info', '視頻信息顯示');
  String get showVideoInfoDesc => _t(
    '文件名/文件大小/分辨率/当前序号',
    'Name / Size / Resolution / Index',
    '文件名/文件大小/分辨率/當前序號',
  );
  String get controlsLabel => _t('快捷键与控制', 'Controls', '快捷鍵與控制');
  String get wheelSwitch => _t('滚轮行为', 'Scroll Wheel', '滾輪行為');
  String get wheelSwitchVideo => _t('切换视频', 'Switch Video', '切換視頻');
  String get wheelZoom => _t('缩放视频', 'Zoom', '縮放視頻');
  String get ctrlWheelZoomHint =>
      _t('Ctrl+滚轮：缩放视频', 'Ctrl + Wheel: Zoom', 'Ctrl+滾輪：縮放視頻');
  String get ctrlWheelSwitchHint =>
      _t('Ctrl+滚轮：切换视频', 'Ctrl + Wheel: Switch Video', 'Ctrl+滾輪：切換視頻');
  String get mobileTapBehavior => _t('短按行为', 'Tap Action', '短按行為');
  String get mobileTapPlay => _t('播放', 'Play', '播放');
  String get mobileTapSelect => _t('选中', 'Select', '選中');
  String get mobileTapPlayDesc => _t('长按选中', 'Long press to select', '長按選中');
  String get mobileTapSelectDesc =>
      _t('长按或再次短按播放', 'Long press or tap again to play', '長按或再次短按播放');
  // Windows 桌面端：右键菜单与默认打开方式
  /// 注册到系统注册表的右键菜单项文字（写入注册表后需重装才会更新）
  String get contextMenuOpenWith =>
      _t('用 SteamFlow 播放', 'Open with SteamFlow', '用 SteamFlow 播放');

  /// ProgID 的文件类型显示名（出现在「打开方式」等系统界面）
  String get videoFileTypeName =>
      _t('SteamFlow 视频文件', 'SteamFlow Video', 'SteamFlow 視頻檔案');

  /// 「默认应用」列表中展示的应用说明
  String get videoPlayerDescription =>
      _t('SteamFlow 视频播放器', 'SteamFlow video player', 'SteamFlow 視頻播放器');

  String get addToContextMenu =>
      _t('添加到右键菜单', 'Add to Context Menu', '添加到右鍵菜單');
  String get addToContextMenuDesc => _t(
    '在支持视频格式的右键菜单中增加一项：用 SteamFlow 播放',
    'Add "Play with SteamFlow" to the context menu of supported video formats',
    '在支援視頻格式的右鍵菜單中增加一項：用 SteamFlow 播放',
  );
  String get contextMenuFailed =>
      _t('操作失败，请检查系统权限', 'Failed. Check system permissions', '操作失敗，請檢查系統權限');
  String get setDefaultPlayer =>
      _t('设为默认播放器', 'Set as Default Player', '設為預設播放器');
  String get setDefaultPlayerDesc => _t(
    '请在系统默认应用>视频播放器>选中SteamFlow',
    'Choose SteamFlow in Default Apps > Video Player',
    '請在系統預設應用程式>視頻播放器>選中SteamFlow',
  );
  String get defaultAppOpen => _t('去设置', 'Open Settings', '前往設定');
  String get defaultAppSettingsOpened => _t(
    '已打开系统「默认应用」页面，请在其中选择 SteamFlow',
    'Default Apps opened. Please choose SteamFlow there.',
    '已開啟系統「預設應用程式」頁面，請在其中選擇 SteamFlow',
  );
  String get deleteBehavior => _t('删除行为', 'Delete', '刪除行為');
  String get ctrlDelDeleteHint =>
      _t('Ctrl+Del：实际删除', 'Ctrl + Del: Delete File', 'Ctrl+Del：實際刪除');
  String get ctrlDelExcludeHint =>
      _t('Ctrl+Del：排除播放', 'Ctrl + Del: Exclude', 'Ctrl+Del：排除播放');
  String get excludeFromPlay => _t('排除播放', 'Exclude', '排除播放');
  String get deleteFile => _t('实际删除', 'Delete File', '實際刪除');
  String get second => _t('秒', 's', '秒');
  String get deleteFromDisk => _t('从磁盘删除', 'Delete from Disk', '從磁盤刪除');
  String get confirmExclude => _t('确认排除', 'Confirm Exclude', '確認排除');
  String get confirmDelete => _t('确认删除', 'Confirm Delete', '確認刪除');
  String confirmDeleteMsg(String action) =>
      _t('确定要$action这个视频吗？', 'Delete this video?', '確定要$action這個視頻嗎？');
  String get deleteFailed =>
      _t('文件删除失败，可能被其他程序占用', 'Delete failed: file in use', '文件刪除失敗，可能被其他程序佔用');
  String get excluded => _t('视频已排除播放', 'Video excluded', '視頻已排除播放');
  String get deleted => _t('视频已删除', 'Video deleted', '視頻已刪除');
  String get shortcutTitle => _t('内置快捷键', 'Shortcuts', '內置快捷鍵');
  String get spaceKey => _t('空格', 'Space', '空格');
  String get playPause => _t('播放/暂停', 'Play / Pause', '播放/暫停');
  String get previous => _t('上一个', 'Previous', '上一個');
  String get next => _t('下一个', 'Next', '下一個');
  String get exitFullscreen => _t('退出全屏', 'Exit Fullscreen', '退出全屏');
  String get exitPlayback => _t('退出播放', 'Exit Playback', '退出播放');
  String get closeApp => _t('关闭', 'Close', '關閉');
  String get enterFullscreen => _t('全屏', 'Fullscreen', '全屏');
  String get rotate => _t('旋转', 'Rotate', '旋轉');
  String get rotateRight => _t('向右旋转', 'Rotate Right', '向右旋轉');
  String get rotateLeft => _t('向左旋转', 'Rotate Left', '向左旋轉');
  String get zoomIn => _t('放大', 'Zoom In', '放大');
  String get zoomOut => _t('缩小', 'Zoom Out', '縮小');
  String get fitScreen => _t('适应屏幕', 'Fit Screen', '適應屏幕');
  String get errorRange => _t(
    '须为大于1且小于65535的整数',
    'Enter a number between 2 and 65534',
    '須為大於1且小於65535的整數',
  );
  String get msgSelectFolderFirst =>
      _t('请先设置要播放的视频目录', 'Select folders first', '請先設置要播放的視頻目錄');
  String get msgReselectFolder =>
      _t('选定的目录下没有视频，请重新选择', 'No videos, please reselect', '選定目錄下沒有視頻，請重新選擇');
  String get msgScanError =>
      _t('扫描视频失败，请重试', 'Scan failed, please retry', '掃描視頻失敗，請重試');
  String get msgAutoScanError => _t('自动扫描失败', 'Auto-scan failed', '自動掃描失敗');
  String get back => _t('返回', 'Back', '返回');

  // 其余页面补充
  String get selectDirWithVideos =>
      _t('请选择一个包含视频的目录', 'Select a folder with videos', '請選擇一個包含視頻的目錄');
  String get unknown => _t('未知', 'Unknown', '未知');
  String get deleteFileLabel => _t('删除文件', 'Delete File', '刪除文件');
  String get needPermissionToRead =>
      _t('需要存储权限才能读取视频', 'Storage permission required', '需要存儲權限才能讀取視頻');
  String videosTotal(int c) => _t('共 $c 个视频', '$c videos', '共 $c 個視頻');
  String videosCount(int c) => _t('$c 个视频', '$c videos', '$c 個視頻');
  String filesCount(int c) => _t('包含$c个文件', '$c files', '包含$c個文件');
  String folderContentCount(int subfolders, int files) => _t(
    '包含$subfolders个子文件夹，共$files个文件',
    '$subfolders subfolders, $files files',
    '包含$subfolders個子文件夾，共$files個文件',
  );

  // 消息
  String msgScanComplete(int c) =>
      _t('扫描完成，共 $c 个视频', 'Done: $c videos', '掃描完成，共 $c 個視頻');
  String get msgNoVideos => _t('选定的目录下没有视频', 'No videos found', '選定目錄下沒有視頻');
  String get msgAddFolderFirst => _t('请先添加文件夹', 'Add folders first', '請先添加文件夾');
  String get msgNeedPermission =>
      _t('需要存储读取权限', 'Permission required', '需要存儲讀取權限');
  String get msgNoAlbumsFound =>
      _t('未找到包含视频的相册', 'No albums found', '未找到包含視頻的相冊');
  String msgScanFailed(Object e) => _t('扫描失败: $e', 'Failed: $e', '掃描失敗: $e');

  // 排除视频浏览
  String get excludedFolder => _t('已排除的视频', 'Excluded Videos', '已排除的視頻');
  String get noExcludedVideos =>
      _t('没有已排除的视频', 'No excluded videos', '沒有已排除的視頻');
  String get videoRestored => _t('视频已恢复', 'Video restored', '視頻已恢復');
  String get allVideosRestored =>
      _t('所有视频已恢复', 'All videos restored', '所有視頻已恢復');
  String get restoreAll => _t('恢复全部', 'Restore All', '恢復全部');
  String get excludeFolderVirtual => _t('已排除的文件', 'Excluded Files', '已排除的文件');
  String get deleteVideo => _t('删除', 'Delete', '刪除');
  String get moveTo => _t('移动到', 'Move To', '移動到');
  String get copyTo => _t('复制到', 'Copy To', '複製到');
  String get restore => _t('恢复', 'Restore', '恢復');
  String get restoreFiles =>
      _t('恢复此文件夹的文件', 'Restore Files in Folder', '恢復此文件夾的文件');
  String get deleteFiles =>
      _t('删除此文件夹的文件', 'Delete Files in Folder', '刪除此文件夾的文件');
  String get removeFromManage => _t('取消管理', 'Stop Managing', '取消管理');
  String get deleteAll => _t('删除全部', 'Delete All', '刪除全部');
  String get moveAllTo => _t('全部移动到', 'Move All To', '全部移動到');
  String get copyAllTo => _t('全部复制到', 'Copy All To', '全部複製到');
  String get deletedAll => _t('全部已删除', 'All deleted', '全部已刪除');
  String get movedAllTo => _t('已全部移动', 'All moved', '已全部移動');
  String get copiedAllTo => _t('已全部复制', 'All copied', '已全部複製');
  String get moveFailed => _t('移动失败', 'Move failed', '移動失敗');
  String get copyFailed => _t('复制失败', 'Copy failed', '複製失敗');
  String get copySuccess => _t('复制成功', 'Copied', '複製成功');
  String get deletedToTrash => _t('已移入回收站', 'Moved to trash', '已移入回收站');
  String get deletedAllToTrash =>
      _t('全部已移入回收站', 'All moved to trash', '全部已移入回收站');

  // 文件夹视频浏览
  String get noVideosInFolder =>
      _t('此文件夹中没有视频', 'No videos in this folder', '此文件夾中沒有視頻');
  String get sortSequential => _t('顺序', 'Ascending', '順序');
  String get sortReverse => _t('逆序', 'Descending', '逆序');
  String get sortNewest => _t('最新', 'Newest', '最新');
  String get sortOldest => _t('最旧', 'Oldest', '最舊');
  String get sortRandom => _t('随机', 'Random', '隨機');
  String get sortBy => _t('排序', 'Sort', '排序');
  String get largestFirst => _t('由大到小', 'Largest First', '由大到小');
  String get smallestFirst => _t('由小到大', 'Smallest First', '由小到大');

  // 帮助页
  String get help => _t('帮助', 'Help', '幫助');
  String get helpDocSection => _t('说明文档', 'Documentation', '說明文檔');
  String get helpAboutSection => _t('关于', 'About', '關於');
  String get helpSponsorSection => _t('赞助', 'Sponsor', '贊助');
  String get helpGroupPlay => _t('播放控制', 'Playback', '播放控制');
  String get helpGroupDisplay => _t('视频显示', 'Video Display', '視頻顯示');
  String get helpGroupTransition => _t('切换动画', 'Transitions', '切換動畫');
  String get helpGroupFullscreen =>
      _t('全屏与工具栏', 'Fullscreen & Toolbar', '全屏與工具欄');
  String get helpGroupFolders => _t('多目录与视频管理', 'Folders & Videos', '多目錄與視頻管理');
  String get helpPlayOrder => _t(
    '多种播放顺序：顺序、逆序、由新到旧、由旧到新、随机、新视频优先',
    'Play orders: ascending, descending, newest first, oldest first, random, new-first',
    '多種播放順序：順序、逆序、由新到舊、由舊到新、隨機、新視頻優先',
  );
  String get helpLoopAuto => _t(
    '循环播放与自动播放可分别开关',
    'Loop and auto-play can be toggled separately',
    '循環播放與自動播放可分別開關',
  );
  String get helpGestures => _t(
    '手势：上下滑动切换视频，左右滑动拖动进度条，点击画面显示或隐藏工具栏',
    'Gestures: swipe up/down to switch videos, swipe left/right to seek, tap to toggle the toolbar',
    '手勢：上下滑動切換視頻，左右滑動拖動進度條，點擊畫面顯示或隱藏工具欄',
  );
  String get helpPlayPause =>
      _t('可随时暂停或继续播放', 'Pause or resume anytime', '可隨時暫停或繼續播放');
  String get helpFitMode => _t(
    '填充模式：适应窗口、填满窗口、原始大小',
    'Fit modes: fit window, fill window, original size',
    '填充模式：適應窗口、填滿窗口、原始大小',
  );
  String get helpBackground =>
      _t('背景色：黑色、深灰、白色', 'Background: black, dark gray, white', '背景色：黑色、深灰、白色');
  String get helpOrientation => _t(
    '屏幕方向：横屏、竖屏、跟随系统、跟随视频',
    'Orientation: landscape, portrait, follow system, follow video',
    '螢幕方向：橫屏、豎屏、跟隨系統、跟隨視頻',
  );
  String get helpZoomPan => _t(
    '缩放与平移：滚轮、触控板捏合或手势缩放（1～5 倍），放大后可左键拖动，右键呼出放大/缩小/适应屏幕/旋转菜单',
    'Zoom & pan: wheel, trackpad pinch or gestures (1x–5x); left-drag to pan, right-click for the zoom/reset/rotate menu',
    '縮放與平移：滾輪、觸控板捏合或手勢縮放（1～5 倍），放大後可左鍵拖動，右鍵呼出放大/縮小/適應屏幕/旋轉選單',
  );
  String get helpWheel => _t(
    '鼠标滚轮可设为切换视频或缩放视频，按住 Ctrl（或 Shift）滚动执行相反操作',
    'The wheel can switch or zoom; hold Ctrl (or Shift) to do the opposite',
    '滑鼠滾輪可設為切換視頻或縮放視頻，按住 Ctrl（或 Shift）滾動執行相反操作',
  );
  String get helpTransition => _t(
    '滚轮/手势切换为上下滑动，工具栏与方向键为左右滑动，自动切换为淡入淡出，统一 0.3 秒',
    'Wheel/gesture slides vertically, toolbar and arrow keys slide horizontally, auto switch fades; all last 0.3s',
    '滾輪/手勢切換為上下滑動，工具欄與方向鍵為左右滑動，自動切換為淡入淡出，統一 0.3 秒',
  );
  String get helpFullscreen => _t(
    'Windows 支持真·全屏，可设置进入播放时自动全屏',
    'True fullscreen on Windows; can enter fullscreen automatically',
    'Windows 支援真·全屏，可設定進入播放時自動全屏',
  );
  String get helpToolbar => _t(
    '工具栏可自动隐藏（延迟可调），也可设置为暂停时保持显示',
    'The toolbar auto-hides with an adjustable delay, or stays while paused',
    '工具欄可自動隱藏（延遲可調），也可設定為暫停時保持顯示',
  );
  String get helpFolders => _t(
    '可添加多个文件夹，可选择是否包含子文件夹，自动去重并统计数量',
    'Add multiple folders, optionally include subfolders, with de-duplication and counts',
    '可添加多個文件夾，可選擇是否包含子文件夾，自動去重並統計數量',
  );
  String get helpFormats => _t(
    '支持 MP4、M4V、MOV、MKV、WebM、AVI、WMV 等常见格式',
    'Supports MP4, M4V, MOV, MKV, WebM, AVI, WMV and more',
    '支援 MP4、M4V、MOV、MKV、WebM、AVI、WMV 等常見格式',
  );
  String get helpExclude => _t(
    '排除播放：把不想看的视频移出播放列表（不删除文件），已排除的视频可恢复或实际删除，也可以移动或者复制到其他位置',
    'Exclude: remove videos from the playlist without deleting files; excluded videos can be restored or deleted, and can also be moved or copied elsewhere',
    '排除播放：把不想看的視頻移出播放列表（不刪除檔案），已排除的視頻可恢復或實際刪除，也可以移動或者複製到其他位置',
  );
  String get helpBrowse => _t(
    '瀑布流浏览：点击任意视频即可播放当前文件夹；文件夹右侧可直接播放该文件夹',
    'Grid browsing: tap any video to play the folder, or use the folder play button',
    '瀑布流瀏覽：點擊任意視頻即可播放當前文件夾；文件夾右側可直接播放該文件夾',
  );
  String get helpInfoDisplay => _t(
    '可显示文件名、大小、分辨率与序号，并支持自动隐藏',
    'Shows file name, size, resolution and index, with auto-hide',
    '可顯示檔案名稱、大小、解析度與序號，並支援自動隱藏',
  );
  String get helpSort => _t(
    '瀑布流右上角可切换排序：名称、时间、大小、随机与新视频优先；每个文件夹会记住上次选择',
    'Sort by name, time, size, random or new-first from the grid menu; each folder remembers its choice',
    '瀑布流右上角可切換排序：名稱、時間、大小、隨機與新視頻優先；每個文件夾會記住上次選擇',
  );
  String get helpGroupLan => _t('内网共享', 'LAN Sharing', '內網共享');
  String get helpLanShare => _t(
    '开启共享后，同一局域网内的其他设备可浏览本机共享文件夹中的视频；两端需使用兼容的 SteamFlow 版本',
    'Enable sharing to let other devices on the same LAN browse your shared folders; both sides must run a compatible SteamFlow version',
    '開啟共享後，同一局域網內的其他設備可瀏覽本機共享文件夾中的視頻；兩端需使用兼容的 SteamFlow 版本',
  );
  String get helpLanPermissions => _t(
    '可分别允许对方远程排除播放、复制视频；两项权限默认关闭',
    'You can allow remote exclude and remote copy separately; both are off by default',
    '可分別允許對方遠程排除播放、複製視頻；兩項權限預設關閉',
  );
  String get helpLanCopy => _t(
    '远程视频支持复制到本地，可随时取消；中断后再次复制会从断点续传，远端文件变化时会自动重下，避免文件损坏',
    'Remote videos can be copied locally and cancelled at any time; interrupted copies resume, and changed remote files restart automatically to avoid corruption',
    '遠程視頻支持複製到本地，可隨時取消；中斷後再次複製會從斷點續傳，遠端文件變化時會自動重下，避免文件損壞',
  );
  String get helpLanTray => _t(
    'Windows 端可开启「关闭时最小化到托盘」，关闭窗口后共享服务继续在后台运行',
    'On Windows, enable “Minimize to Tray on Close” to keep sharing in the background after closing the window',
    'Windows 端可開啟「關閉時最小化到托盤」，關閉窗口後共享服務繼續在後台運行',
  );
  String get helpVersionLabel => _t('版本', 'Version', '版本');
  String get helpGitHub =>
      _t('GitHub 项目主页', 'GitHub Repository', 'GitHub 專案主頁');
  String get helpSponsorDesc => _t(
    '本应用完全免费、无广告，如果它帮到了你，欢迎赞助支持。',
    'This app is completely free and ad-free. If it helps you, a donation is welcome.',
    '本應用完全免費、無廣告，如果它幫到了你，歡迎贊助支持。',
  );
  String get helpSponsorButton => _t('打开赞助页面', 'Open Sponsor Page', '打開贊助頁面');

  // ── 内网共享 ──
  String get lanSharePageTitle => _t('内网共享', 'LAN Sharing', '內網共享');
  String get lanShareTitle => _t('共享本机视频', 'Share This Device', '共享本機視頻');
  String get lanShareDesc => _t(
    '允许同一局域网内的设备浏览并播放所选文件夹中的视频',
    'Let devices on the same LAN browse and play videos in selected folders',
    '允許同一局域網內的設備瀏覽並播放所選文件夾中的視頻',
  );
  String get lanShareFolderSwitchHint =>
      _t('选择要共享的文件夹', 'Choose folders to share', '選擇要共享的文件夾');
  String get localFoldersSection => _t('本地文件夹', 'Local Folders', '本地文件夾');
  String get playLocalFolders =>
      _t('播放全部本地文件夹', 'Play all local folders', '播放全部本地文件夾');
  String get playSharedFolders =>
      _t('播放全部共享文件夹', 'Play all shared folders', '播放全部共享文件夾');
  String get addShareSource => _t('添加共享源', 'Add Shared Source', '添加共享源');
  String get lanSelectSharedFoldersHint =>
      _t('选择要添加的共享文件夹', 'Select shared folders to add', '選擇要添加的共享文件夾');
  String lanLocalAddressWith(String addresses) =>
      _t('本机地址：$addresses', 'Local address: $addresses', '本機地址：$addresses');
  String get lanShareKeepAwakeHint => _t(
    '停留在该页面时手机会保持常亮，以便其他终端读取播放本机共享的文件',
    'The screen stays awake while this page is open so other devices can read your shared files',
    '停留在該頁面時手機會保持常亮，以便其他終端讀取播放本機共享的文件',
  );
  String get lanShareBatteryHint => _t(
    '如果觉得屏幕常亮太耗电，可以返回主界面或手动关屏；这些操作可能导致断连，具体情况与手机品牌和省电策略相关。',
    'If keep-awake drains too much battery, you can return to the home screen or turn off the screen. Either may cause a disconnect; behavior depends on your phone brand and power-saving policy.',
    '如果覺得屏幕常亮太耗電，可以返回主界面或手動關屏；這些操作可能導致斷連，具體情況與手機品牌和省電策略相關。',
  );
  String get lanServerStartFailed => _t(
    '共享服务启动失败，请检查网络或端口占用',
    'Failed to start sharing; check the network or port usage',
    '共享服務啟動失敗，請檢查網絡或端口佔用',
  );
  String get allowRemoteExcludeLabel =>
      _t('允许远程排除播放', 'Allow Remote Exclude', '允許遠端排除播放');
  String get allowRemoteExcludeDesc => _t(
    '便于远程管理，不会实际删除文件，可一键恢复',
    'Easy remote management; files are not deleted and can be restored anytime',
    '便於遠程管理，不會實際刪除檔案，可一鍵恢復',
  );
  String get allowRemoteCopyLabel => _t('允许下载', 'Allow Downloads', '允許下載');
  String get allowRemoteCopyDesc => _t(
    '允许内网其他终端下载本机视频',
    'Allow other devices on the LAN to download videos from this device',
    '允許內網其他終端下載本機視頻',
  );
  String get lanNoDevices => _t('未发现内网设备', 'No devices found', '未發現內網設備');
  String get lanManualAdd => _t('手动添加设备', 'Add Device Manually', '手動添加設備');
  String get lanManualHint =>
      _t('输入 IP 或 IP:端口', 'Enter IP or IP:port', '輸入 IP 或 IP:端口');
  String get lanInvalidAddress =>
      _t('地址无效或设备不可达', 'Invalid address or device unreachable', '地址無效或設備不可達');
  String get lanSelfDevice =>
      _t('这是本机设备', 'This is the current device', '這是本機設備');
  String lanSharedFoldersCount(int count) =>
      _t('共享 $count 个文件夹', '$count shared folders', '共享 $count 個文件夾');
  String lanVideoCount(int count) =>
      _t('$count 个视频', '$count videos', '$count 個視頻');
  String get lanNoFolders =>
      _t('对方没有共享任何文件夹', 'The device shares no folders', '對方沒有共享任何文件夾');
  String get lanLoadFailed => _t(
    '加载失败，请确认设备在线',
    'Load failed. Check the device is online',
    '加載失敗，請確認設備在線',
  );
  String get lanRefresh => _t('刷新', 'Refresh', '刷新');
  String get lanCancel => _t('取消', 'Cancel', '取消');
  String get lanAdd => _t('添加', 'Add', '添加');
  String get lanRetry => _t('重试', 'Retry', '重試');
  String get lanRemove => _t('移除', 'Remove', '移除');
  String get lanAddSource => _t('添加共享源', 'Add Shared Source', '添加共享源');
  String get lanAdded => _t('已添加共享源', 'Shared source added', '已添加共享源');
  String get sharedFoldersSection => _t('共享文件夹', 'Shared Folders', '共享文件夾');
  String get lanReconnectFolder => _t('重新连接', 'Reconnect', '重新連接');
  String get lanReconnectAll => _t('重新连接全部', 'Reconnect all', '重新連接全部');
  String get lanReconnectFailed => _t(
    '重连失败，请确认共享设备在线',
    'Reconnect failed. Check the shared device is online',
    '重連失敗，請確認共享設備在線',
  );
  String get lanRemoteUnsupported => _t(
    '远程视频暂不支持该操作',
    'This action is not supported for remote videos yet',
    '遠程視頻暫不支持該操作',
  );
  String get lanCopyToLocal => _t('复制到本地', 'Copy to Local', '複製到本機');
  String get lanCopied => _t('已复制到本地', 'Copied', '已複製到本機');
  String get lanCopyFailed => _t('复制失败', 'Copy failed', '複製失敗');
  String get lanRemotePermissionDenied => _t(
    '对方未开启该权限',
    'The other device has not enabled this permission',
    '對方未開啟該權限',
  );
  String get lanRemoteExcludeFailed => _t(
    '远程排除失败，请确认对方已开启该权限',
    'Remote exclude failed; make sure it is enabled on the sharing device',
    '遠程排除失敗，請確認對方已開啟該權限',
  );
  String get lanCopying => _t('正在复制…', 'Copying…', '正在複製…');
  String get lanCopyCancelled => _t('已取消复制', 'Copy cancelled', '已取消複製');
  String get lanCopyBusy =>
      _t('已有复制任务进行中', 'A copy task is already running', '已有複製任務進行中');
  String get lastCopyDestination =>
      _t('上次使用的目录', 'Last used folder', '上次使用的目錄');
  String get changeDestination => _t('更改目录', 'Change Folder', '更改目錄');
  String get startCopy => _t('开始复制', 'Start Copy', '開始複製');

  // 桌面端托盘
  String get trayShowWindow => _t('显示主界面', 'Show Window', '顯示主界面');
  String get trayExit => _t('退出 SteamFlow', 'Exit SteamFlow', '退出 SteamFlow');
  String get closeToTray =>
      _t('关闭时最小化到托盘', 'Minimize to Tray on Close', '關閉時最小化到托盤');
  String get closeToTrayDesc => _t(
    '关闭窗口时收起到系统托盘继续运行，以便其他内网终端浏览本机视频',
    'Keep running in the system tray when the window is closed so other LAN devices can keep browsing your videos',
    '關閉窗口時收起到系統托盤繼續運行，以便其他內網終端瀏覽本機視頻',
  );

  // 内部翻译方法
  String _t(String zhCN, String en, String zhTW) {
    if (isZhCN) return zhCN;
    if (isZhTW) return zhTW;
    return en;
  }
}
