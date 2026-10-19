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
  String get selectFolder => _t('选择文件夹', 'Folders', '選擇文件夾');
  String get settings => _t('设置', 'Settings', '設置');
  String get scanning => _t('正在扫描视频...', 'Scanning...', '正在掃描視頻...');

  // 相册选择页
  String get selectAlbumTitle => _t('选择相册', 'Albums', '選擇相冊');
  String get selectFolderTitle => _t('选择文件夹', 'Folders', '選擇文件夾');
  String get addAlbum => _t('添加相册', 'Add Album', '添加相冊');
  String get addFolder => _t('添加文件夹', 'Add Folder', '添加文件夾');
  String get excludeAll => _t('全部排除', 'Exclude All', '全部排除');
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
  String get loopPlay => _t('循环播放', 'Loop', '循環播放');
  String get loopPlayDesc =>
      _t('关闭：播完停止；开启：首尾循环', 'Off: stop at end; On: loop', '關閉：播完停止；開啟：首尾循環');
  String get volume => _t('音量', 'Volume', '音量');
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
  String get transitionAnimation => _t('切换动画', 'Transition', '切換動畫');
  String get none => _t('无动画', 'None', '無動畫');
  String get fade => _t('淡入淡出', 'Fade', '淡入淡出');
  String get slideLeft => _t('左右滑动', 'Slide Left', '左右滑動');
  String get slideUp => _t('上下滑动', 'Slide Up', '上下滑動');
  String get animDuration => _t('动画时长', 'Duration', '動畫時長');
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
  String get filesAndDirs => _t('文件与目录', 'Files & Folders', '文件與目錄');
  String get recursiveScan => _t('包含子文件夹', 'Include Subfolders', '包含子文件夾');
  String get recursiveScanDesc => _t(
    '开启后连子文件夹里的视频一起播放',
    'Play videos from subfolders too',
    '開啟後連子文件夾裡的視頻一起播放',
  );
  String get fileListInfo => _t('文件列表信息', 'File List Info', '文件列表信息');
  String get fileListInfoDesc => _t(
    '选中项显示在瀑布流卡片下方',
    'Show the selected field under each grid card',
    '選中項顯示在瀑布流卡片下方',
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
  String includesVideos(int c) =>
      _t('包含 $c 个视频', 'Includes $c videos', '包含 $c 個視頻');
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
    '淡入淡出、左右滑动、上下滑动、无动画',
    'Fade, slide horizontally, slide vertically, none',
    '淡入淡出、左右滑動、上下滑動、無動畫',
  );
  String get helpAnimDuration => _t(
    '动画时长 0.1～1.0 秒可调',
    'Animation duration adjustable from 0.1s to 1.0s',
    '動畫時長 0.1～1.0 秒可調',
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
  String get helpVersionLabel => _t('版本', 'Version', '版本');
  String get helpGitHub =>
      _t('GitHub 项目主页', 'GitHub Repository', 'GitHub 專案主頁');
  String get helpSponsorDesc => _t(
    '本应用完全免费、无广告，如果它帮到了你，欢迎赞助支持。',
    'This app is completely free and ad-free. If it helps you, a donation is welcome.',
    '本應用完全免費、無廣告，如果它幫到了你，歡迎贊助支持。',
  );
  String get helpSponsorButton => _t('打开赞助页面', 'Open Sponsor Page', '打開贊助頁面');

  // 内部翻译方法
  String _t(String zhCN, String en, String zhTW) {
    if (isZhCN) return zhCN;
    if (isZhTW) return zhTW;
    return en;
  }
}
