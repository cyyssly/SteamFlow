# SteamFlow - 跨平台视频管理与播放器

一款基于 Flutter 开发的跨平台视频管理与播放器，支持 Windows、macOS、Linux、Android 和 iOS 平台。提供沉浸式的全屏视频播放与浏览体验，支持中文（简体/繁体）与英文界面、多种播放模式、切换动画和丰富的自定义设置。本应用无广告，完全免费，可自由分享。

## 功能特性

### 播放控制
- **多种播放顺序** — 顺序播放（按文件名）、随机播放、由新到旧（按修改时间）、由旧到新（按修改时间）、新视频优先
- **循环播放** — 可开启/关闭循环播放，播完即止
- **自动播放** — 进入应用后自动扫描并开始播放
- **换片时间可调** — 预设多档（1 秒～10 分钟），也可自定义（2～65534 秒）
- **播放/暂停** — 随时控制播放进度；放大查看时自动暂停，点播放即视为看完当前这个，直接切下一个

### 视频显示
- **多种填充模式** — `适应窗口`（contain）、`填满窗口`（cover）或 `原始大小`
- **背景色选择** — 黑色、深灰、白色三种背景色
- **屏幕方向控制** — 横屏、竖屏、跟随系统、跟随视频（自动旋转视频长边至屏幕长边）
- **缩放与平移** — 滚轮、触控板捏合或手势缩放（1～5 倍，以光标/触点为中心），放大后可用左键拖动平移；拖到左右边缘并继续外推，松开左键才切换到上一个/下一个；右键菜单可放大/缩小/适应屏幕/旋转
- **鼠标滚轮** — 可设置为切换视频或缩放视频；按住 `Ctrl`（或 `Shift`）滚动执行相反操作

### 切换动画
- **手动切换** — 滚轮或手势切换时，按方向上下滑动
- **工具栏 / 方向键切换** — 点击工具栏上一页/下一页或按左右方向键时，按方向左右滑动
- **自动切换** — 播放结束自动切到下一个时使用淡入淡出
- **固定时长** — 所有换片动画统一为 0.3 秒

### 全屏模式
- **真·全屏（Windows）** — 通过 Win32 API 实现真正的无边框全屏
- **播放时自动全屏** — 进入播放页自动切换全屏
- **工具栏自动隐藏** — 无操作后自动隐藏控制栏，可自定义延迟时间
- **暂停时保持工具栏** — 暂停播放时不隐藏控制栏

### 多目录支持
- **添加多个文件夹** — 支持同时添加多个视频目录
- **包含子文件夹** — 可选择是否包含子文件夹
- **文件去重** — 自动按文件路径去重
- **实时统计** — 显示每个文件夹的视频数量和子文件夹数量
- **支持的格式** — MP4、M4V、MOV、MKV、WebM、AVI、WMV 等常见格式

### 视频管理
- **排除播放** — 将不喜欢的视频从播放列表中排除（不移除文件）
- **实际删除** — 直接从磁盘删除视频（需二次确认）
- **反向操作** — 按住 `Ctrl` 再按 `Del`，执行与"删除行为"设置相反的动作
- **已排除的视频** — 已排除的视频会在选择文件夹页面展示，支持恢复、删除、复制到、剪切到等操作

### 信息显示
- **视频信息** — 文件名、文件大小、分辨率、当前序号
- **信息条自动隐藏** — 几秒无操作自动消失，可自定义延迟

### 快捷键

播放页面支持丰富的键盘快捷键操作：

| 快捷键 | 功能 |
|--------|------|
| `Space` | 播放/暂停（放大状态下＝复位缩放并直接切下一个） |
| `←` | 上一个 |
| `→` | 下一个 |
| `↑` | 放大视频 |
| `↓` | 缩小视频 |
| `R` | 向右旋转 90° |
| `L` | 向左旋转 90° |
| `Ctrl` + `=` / `Ctrl` + `-` | 放大 / 缩小 |
| `Ctrl` + `0` | 适应屏幕（复位缩放） |
| `Del` | 按"删除行为"设置执行：排除播放 / 实际删除 |
| `Ctrl` + `Del` | 执行与"删除行为"相反的操作 |
| `F11` | 切换全屏 |
| `Esc` | 退出全屏；非全屏时退出播放 |

### 鼠标与触控板

| 操作 | 功能 |
|------|------|
| 滚轮 | 按"滚轮行为"设置执行：切换视频 / 缩放视频 |
| `Ctrl`（或 `Shift`）+ 滚轮 | 执行与"滚轮行为"相反的操作 |
| 触控板双指捏合 | 以触点为中心缩放视频 |
| 放大后左键拖动 | 平移视频 |
| 放大后拖到边缘并继续外推 | 松开左键时切换到上一个 / 下一个 |
| 右键单击 | 呼出菜单：放大 / 缩小 / 适应屏幕 / 旋转 |
| 左右拖动/甩动 | 未放大时切换上一个 / 下一个 |

### 设置持久化

所有设置自动保存，下次启动自动恢复。

## 技术栈

- **框架**: Flutter 3.x
- **语言**: Dart ^3.12.2
- **状态管理**: Provider
- **本地存储**: SharedPreferences
- **文件选择**: FilePicker
- **缩略图编码**: image 库（Windows Shell 取帧 / Android MediaMetadataRetriever）
- **平台支持**: Windows (FFI)、macOS、Linux、Android、iOS

## 快速开始

### 环境要求

- Flutter SDK >= 3.0
- Dart SDK ^3.12.2

### 安装与运行

```bash
# 1. 克隆项目
git clone https://github.com/cyyssly/SteamFlow.git
cd SteamFlow

# 2. 获取依赖
flutter pub get

# 3. 运行（调试模式）
flutter run

# 4. 构建发布版本
# Windows
flutter build windows

# macOS
flutter build macos

# Linux
flutter build linux

# Android
flutter build apk

# iOS
flutter build ios
```

> **Windows 用户**: 项目根目录提供了 `run_windows.bat` 和 `build_windows.bat` 便捷脚本，可直接双击运行。

### 项目结构

```
steam_flow/
├── lib/
│   ├── main.dart                     # 应用入口
│   ├── l10n/
│   │   └── app_localizations.dart    # 国际化文案（简体/繁体/英文）
│   ├── models/
│   │   └── video_item.dart           # 视频数据模型
│   ├── providers/
│   │   ├── slide_provider.dart       # 播放状态管理
│   │   └── settings_provider.dart    # 设置状态管理
│   ├── screens/
│   │   ├── home_screen.dart          # 主界面
│   │   ├── player_screen.dart        # 播放界面
│   │   ├── settings_screen.dart      # 设置界面
│   │   ├── folder_selection_screen.dart  # 目录选择界面
│   │   ├── folder_videos_screen.dart # 文件夹内的视频列表
│   │   ├── excluded_videos_screen.dart   # 已排除的视频
│   │   └── help_screen.dart          # 帮助界面
│   ├── services/
│   │   ├── video_scan_service.dart   # 视频扫描
│   │   ├── video_thumbnail_service.dart  # 视频首帧缩略图
│   │   ├── video_thumbnail_win.dart  # Windows Shell 取帧（FFI）
│   │   ├── media_store_service.dart  # Android 媒体库读取
│   │   ├── directory_picker_service.dart  # 目录选择
│   │   └── fullscreen_service.dart   # 全屏控制
│   ├── utils/
│   │   └── rotated_fit.dart          # 旋转后的自适应排版
│   └── widgets/
│       └── masonry_video_grid.dart   # 瀑布流视频网格
├── android/                          # Android 平台配置
├── ios/                              # iOS 平台配置
├── windows/                          # Windows 平台配置
├── web/                              # Web 平台配置
├── test/                             # 测试文件
├── pubspec.yaml                      # 项目配置
├── analysis_options.yaml             # 代码分析配置
└── README.md
```

## 配置说明

所有设置项通过 `shared_preferences` 持久化到本地，无需数据库。

### 主要配置分类

| 分类 | 说明 |
|------|------|
| 播放基础设置 | 换片时间、播放顺序（顺序/随机/由新到旧/由旧到新/新视频优先）、循环播放、自动播放、播放时自动全屏 |
| 视频显示设置 | 填充模式（适应窗口/填满窗口/原始大小）、背景底色、屏幕方向 |
| 工具栏 | 工具栏自动隐藏、隐藏延迟、暂停时保持工具栏 |
| 文件管理 | 包含子文件夹、文件列表信息、浏览格式（瀑布流 / 正方形 / 横屏 4:3、16:9 / 竖屏 3:4、9:16） |
| 信息显示设置 | 视频信息显示、信息条自动隐藏 |
| 快捷键与控制 | 滚轮行为（`Ctrl`/`Shift` 反向）、删除行为（`Ctrl+Del` 反向）、短按行为（手机端：播放 / 选中） |

## 关于作者

- **GitHub**: [cyyssly](https://github.com/cyyssly)
- **爱发电**: [sly345678](https://ifdian.net/a/sly345678/plan)

如果你觉得这个项目有帮助，欢迎[赞助支持](https://ifdian.net/a/sly345678/plan) ❤️

## 许可证

本项目基于 MIT 许可证开源，详见 `LICENSE` 文件。
