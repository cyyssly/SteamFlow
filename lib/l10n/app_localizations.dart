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
  String get scanning => _t('正在扫描图片...', 'Scanning...', '正在掃描圖片...');

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
  String get noImages => _t('没有图片', 'No Images', '沒有圖片');
  String get imageLoadFailed => _t('图片加载失败', 'Load Failed', '圖片加載失敗');
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
  String get newPreferred => _t('新图优先', 'New Preferred', '新圖優先');
  String get loopPlay => _t('循环播放', 'Loop', '循環播放');
  String get loopPlayDesc =>
      _t('关闭：播完停止；开启：首尾循环', 'Off: stop at end; On: loop', '關閉：播完停止；開啟：首尾循環');
  String get autoPlay => _t('自动播放', 'Auto Play', '自動播放');
  String get autoPlayDesc =>
      _t('进入应用后立即开始播放幻灯片', 'Start slideshow on launch', '進入應用後立即開始播放幻燈片');
  String get minute => _t('分钟', 'min', '分鐘');
  String get toggleFullscreen => _t('全屏切换', 'Toggle Fullscreen', '全屏切換');
  String get interval => _t('换片时间', 'Interval', '換片時間');
  String get imageDisplay => _t('图片显示', 'Display', '圖片顯示');
  String get fitMode => _t('填充模式', 'Fit Mode', '填充模式');
  String get contain => _t('适应窗口', 'Contain', '適應窗口');
  String get cover => _t('填满窗口', 'Cover', '填滿窗口');
  String get original => _t('原图大小', 'Original', '原圖大小');
  String get backgroundColorLabel => _t('背景底色', 'Background', '背景底色');
  String get black => _t('黑色', 'Black', '黑色');
  String get darkGray => _t('深灰', 'Dark Gray', '深灰');
  String get white => _t('白色', 'White', '白色');
  String get orientationLabel => _t('屏幕方向', 'Orientation', '屏幕方向');
  String get landscape => _t('横屏', 'Landscape', '橫屏');
  String get portrait => _t('竖屏', 'Portrait', '豎屏');
  String get followSystem => _t('跟随系统', 'System', '跟隨係統');
  String get followImage => _t('跟随图片', 'Follow Image', '跟隨圖片');
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
    '开启后连子文件夹里的图片一起播放',
    'Play images from subfolders too',
    '開啟後連子文件夾裡的圖片一起播放',
  );
  String get infoDisplay => _t('信息显示', 'Info', '信息顯示');
  String get showImageInfo => _t('图片信息显示', 'Show Info', '圖片信息顯示');
  String get showImageInfoDesc => _t(
    '文件名/文件大小/分辨率/当前页码',
    'Name / Size / Resolution / Page',
    '文件名/文件大小/分辨率/當前頁碼',
  );
  String get infoAutoHideLabel => _t('信息条自动隐藏', 'Auto-hide Info', '信息條自動隱藏');
  String get infoAutoHideDesc =>
      _t('几秒无操作自动消失', 'Hide after idle seconds', '幾秒無操作自動消失');
  String get infoHideDelay => _t('信息隐藏延迟', 'Info Hide Delay', '信息隱藏延遲');
  String get controlsLabel => _t('快捷键与控制', 'Controls', '快捷鍵與控制');
  String get wheelSwitch => _t('滚轮行为', 'Scroll Wheel', '滾輪行為');
  String get wheelSwitchImage => _t('切换图片', 'Switch Image', '切換圖片');
  String get wheelZoom => _t('缩放图片', 'Zoom', '縮放圖片');
  String get ctrlWheelZoomHint =>
      _t('Ctrl+滚轮：缩放图片', 'Ctrl + Wheel: Zoom', 'Ctrl+滾輪：縮放圖片');
  String get ctrlWheelSwitchHint =>
      _t('Ctrl+滚轮：切换图片', 'Ctrl + Wheel: Switch Image', 'Ctrl+滾輪：切換圖片');
  String get deleteBehavior => _t('删除行为', 'Delete', '刪除行為');
  String get ctrlDelDeleteHint =>
      _t('Ctrl+Del：实际删除', 'Ctrl + Del: Delete File', 'Ctrl+Del：實際刪除');
  String get ctrlDelExcludeHint =>
      _t('Ctrl+Del：排除播放', 'Ctrl + Del: Exclude', 'Ctrl+Del：排除播放');
  String get excludeFromPlay => _t('排除播放', 'Exclude', '排除播放');
  String get deleteFile => _t('实际删除', 'Delete File', '實際刪除');
  String get second => _t('秒', 's', '秒');
  String get deleteFromDisk => _t('从磁盘删除', 'Delete from Disk', '從磁盤刪除');
  String get playbackComplete => _t('播放完毕', 'Playback Complete', '播放完畢');
  String get allImagesPlayed =>
      _t('所有图片已播放完毕', 'All images have been shown', '所有圖片已播放完畢');
  String get confirmExclude => _t('确认排除', 'Confirm Exclude', '確認排除');
  String get confirmDelete => _t('确认删除', 'Confirm Delete', '確認刪除');
  String confirmDeleteMsg(String action) =>
      _t('确定要$action这张图片吗？', 'Delete this image?', '確定要$action這張圖片嗎？');
  String get deleteFailed =>
      _t('文件删除失败，可能被其他程序占用', 'Delete failed: file in use', '文件刪除失敗，可能被其他程序佔用');
  String get excluded => _t('图片已排除播放', 'Image excluded', '圖片已排除播放');
  String get deleted => _t('图片已删除', 'Image deleted', '圖片已刪除');
  String get shortcutTitle => _t('内置快捷键', 'Shortcuts', '內置快捷鍵');
  String get spaceKey => _t('空格', 'Space', '空格');
  String get playPause => _t('播放/暂停', 'Play / Pause', '播放/暫停');
  String get previous => _t('上一张', 'Previous', '上一張');
  String get next => _t('下一张', 'Next', '下一張');
  String get exitFullscreen => _t('退出全屏', 'Exit Fullscreen', '退出全屏');
  String get exitPlayback => _t('退出播放', 'Exit Playback', '退出播放');
  String get enterFullscreen => _t('全屏', 'Fullscreen', '全屏');
  String get rotate => _t('旋转', 'Rotate', '旋轉');
  String get rotateRight => _t('向右旋转', 'Rotate Right', '向右旋轉');
  String get rotateLeft => _t('向左旋转', 'Rotate Left', '向左旋轉');
  String get zoomIn => _t('放大', 'Zoom In', '放大');
  String get zoomOut => _t('缩小', 'Zoom Out', '縮小');
  String get fitScreen => _t('适应屏幕', 'Fit Screen', '適應屏幕');
  String get customIntervalLabel =>
      _t('自定义换片时间：', 'Custom interval:', '自訂換片時間：');
  String get errorRange => _t(
    '须为大于1且小于65535的整数',
    'Enter a number between 2 and 65534',
    '須為大於1且小於65535的整數',
  );
  String get msgSelectFolderFirst =>
      _t('请先设置要播放幻灯的图片目录', 'Select folders first', '請先設置要播放幻燈的圖片目錄');
  String get msgReselectFolder =>
      _t('选定的目录下没有图片，请重新选择', 'No images, please reselect', '選定目錄下沒有圖片，請重新選擇');
  String get msgScanError =>
      _t('扫描图片失败，请重试', 'Scan failed, please retry', '掃描圖片失敗，請重試');
  String get msgAutoScanError => _t('自动扫描失败', 'Auto-scan failed', '自動掃描失敗');
  String get back => _t('返回', 'Back', '返回');

  // 其余页面补充
  String get selectDirWithImages =>
      _t('请选择一个包含图片的目录', 'Select a folder with images', '請選擇一個包含圖片的目錄');
  String get unknown => _t('未知', 'Unknown', '未知');
  String get deleteFileLabel => _t('删除文件', 'Delete File', '刪除文件');
  String get needPermissionToRead =>
      _t('需要存储权限才能读取图片', 'Storage permission required', '需要存儲權限才能讀取圖片');
  String imagesTotal(int c) => _t('共 $c 张图片', '$c images', '共 $c 張圖片');
  String imagesCount(int c) => _t('$c 张图片', '$c images', '$c 張圖片');
  String includesImages(int c) =>
      _t('包含 $c 张图片', 'Includes $c images', '包含 $c 張圖片');
  String filesCount(int c) => _t('包含$c个文件', '$c files', '包含$c個文件');
  String folderContentCount(int subfolders, int files) => _t(
    '包含$subfolders个子文件夹，共$files个文件',
    '$subfolders subfolders, $files files',
    '包含$subfolders個子文件夾，共$files個文件',
  );

  // 消息
  String msgScanComplete(int c) =>
      _t('扫描完成，共 $c 张图片', 'Done: $c images', '掃描完成，共 $c 張圖片');
  String get msgNoImages => _t('选定的目录下没有图片', 'No images found', '選定目錄下沒有圖片');
  String get msgAddFolderFirst => _t('请先添加文件夹', 'Add folders first', '請先添加文件夾');
  String get msgNeedPermission =>
      _t('需要存储读取权限', 'Permission required', '需要存儲讀取權限');
  String get msgNoAlbumsFound =>
      _t('未找到包含图片的相册', 'No albums found', '未找到包含圖片的相冊');
  String msgScanFailed(Object e) => _t('扫描失败: $e', 'Failed: $e', '掃描失敗: $e');

  // 排除图片浏览
  String get excludedFolder => _t('已排除的图片', 'Excluded Images', '已排除的圖片');
  String get noExcludedImages =>
      _t('没有已排除的图片', 'No excluded images', '沒有已排除的圖片');
  String get imageRestored => _t('图片已恢复', 'Image restored', '圖片已恢復');
  String get allImagesRestored =>
      _t('所有图片已恢复', 'All images restored', '所有圖片已恢復');
  String get restoreAll => _t('恢复全部', 'Restore All', '恢復全部');
  String get excludeFolderVirtual => _t('已排除的文件', 'Excluded Files', '已排除的文件');
  String get deleteImage => _t('删除', 'Delete', '刪除');
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

  // 文件夹图片浏览
  String get noImagesInFolder =>
      _t('此文件夹中没有图片', 'No images in this folder', '此文件夾中沒有圖片');
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
  String get helpGroupDisplay => _t('图片显示', 'Image Display', '圖片顯示');
  String get helpGroupTransition => _t('切换动画', 'Transitions', '切換動畫');
  String get helpGroupFullscreen =>
      _t('全屏与工具栏', 'Fullscreen & Toolbar', '全屏與工具欄');
  String get helpGroupFolders => _t('多目录与图片管理', 'Folders & Images', '多目錄與圖片管理');
  String get helpPlayOrder => _t(
    '多种播放顺序：顺序、逆序、由新到旧、由旧到新、随机、新图优先',
    'Play orders: ascending, descending, newest first, oldest first, random, new-first',
    '多種播放順序：順序、逆序、由新到舊、由舊到新、隨機、新圖優先',
  );
  String get helpLoopAuto => _t(
    '循环播放与自动播放可分别开关',
    'Loop and auto-play can be toggled separately',
    '循環播放與自動播放可分別開關',
  );
  String get helpInterval => _t(
    '换片时间可调：预设 1 秒～10 分钟，也可自定义（2～65534 秒）',
    'Interval: presets from 1s to 10min, or a custom value (2–65534s)',
    '換片時間可調：預設 1 秒～10 分鐘，也可自訂（2～65534 秒）',
  );
  String get helpPauseZoom => _t(
    '可随时暂停/继续；放大查看时自动暂停，点击播放即切到下一张',
    'Pause or resume anytime; auto-pauses while zoomed, next slide on play',
    '可隨時暫停/繼續；放大檢視時自動暫停，點擊播放即切到下一張',
  );
  String get helpFitMode => _t(
    '填充模式：适应窗口、填满窗口、原图大小',
    'Fit modes: fit window, fill window, original size',
    '填充模式：適應窗口、填滿窗口、原圖大小',
  );
  String get helpBackground =>
      _t('背景色：黑色、深灰、白色', 'Background: black, dark gray, white', '背景色：黑色、深灰、白色');
  String get helpOrientation => _t(
    '屏幕方向：横屏、竖屏、跟随系统、跟随图片',
    'Orientation: landscape, portrait, follow system, follow image',
    '螢幕方向：橫屏、豎屏、跟隨系統、跟隨圖片',
  );
  String get helpZoomPan => _t(
    '缩放与平移：滚轮、触控板捏合或手势缩放（1～5 倍），放大后可左键拖动，右键呼出放大/缩小/适应屏幕/旋转菜单',
    'Zoom & pan: wheel, trackpad pinch or gestures (1x–5x); left-drag to pan, right-click for the zoom/reset/rotate menu',
    '縮放與平移：滾輪、觸控板捏合或手勢縮放（1～5 倍），放大後可左鍵拖動，右鍵呼出放大/縮小/適應屏幕/旋轉選單',
  );
  String get helpWheel => _t(
    '鼠标滚轮可设为切换图片或缩放图片，按住 Ctrl（或 Shift）滚动执行相反操作',
    'The wheel can switch or zoom; hold Ctrl (or Shift) to do the opposite',
    '滑鼠滾輪可設為切換圖片或縮放圖片，按住 Ctrl（或 Shift）滾動執行相反操作',
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
    '支持 JPG、JPEG、PNG、WebP、BMP、GIF、TIFF 等常见格式',
    'Supports JPG, JPEG, PNG, WebP, BMP, GIF, TIFF and more',
    '支援 JPG、JPEG、PNG、WebP、BMP、GIF、TIFF 等常見格式',
  );
  String get helpExclude => _t(
    '排除播放：把不想看的图片移出播放列表（不删除文件），已排除的图片可恢复或实际删除，也可以移动或者复制到其他位置',
    'Exclude: remove images from the playlist without deleting files; excluded images can be restored or deleted, and can also be moved or copied elsewhere',
    '排除播放：把不想看的圖片移出播放列表（不刪除檔案），已排除的圖片可恢復或實際刪除，也可以移動或者複製到其他位置',
  );
  String get helpBrowse => _t(
    '瀑布流浏览：点击任意图片即可播放当前文件夹；文件夹右侧可直接播放该文件夹',
    'Grid browsing: tap any image to play the folder, or use the folder play button',
    '瀑布流瀏覽：點擊任意圖片即可播放當前文件夾；文件夾右側可直接播放該文件夾',
  );
  String get helpInfoDisplay => _t(
    '可显示文件名、大小、分辨率与页码，并支持自动隐藏',
    'Shows file name, size, resolution and page number, with auto-hide',
    '可顯示檔案名稱、大小、解析度與頁碼，並支援自動隱藏',
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
