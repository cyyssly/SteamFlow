import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:steam_flow/l10n/app_localizations.dart';

/// 展示用版本号（与 pubspec.yaml 的 version 保持一致，改版本时需同步）
const String appVersionLabel = 'V1.1.0';

/// 帮助页：说明文档 / 关于 / 赞助
///
/// 其中说明文档是 README 的简化版，只保留功能说明，不含技术类信息。
/// 宽屏为「左侧菜单 + 右侧内容」两栏布局，窄屏/手机端保持从上到下的单栏布局。
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  static const String githubUrl = 'https://github.com/cyyssly/SteamFlow';
  static const String sponsorUrl = 'https://ifdian.net/a/sly345678/plan';

  /// 宽度达到该值（且非手机端）时使用两栏布局
  static const double _twoColumnBreakpoint = 900;

  /// 手机端没有键盘，不展示快捷键说明
  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  /// 两栏布局下右侧显示的分区：0 说明文档、1 关于、2 赞助
  int _sectionIndex = 0;

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.help),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumn =
              !HelpScreen._isMobile &&
              constraints.maxWidth >= HelpScreen._twoColumnBreakpoint;
          return useTwoColumn ? _buildTwoColumn(loc) : _buildSingleColumn(loc);
        },
      ),
    );
  }

  /// 手机端/窄屏：三部分从上到下依次展示
  Widget _buildSingleColumn(AppLocalizations loc) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      _sectionTitle(loc.helpDocSection),
      ..._docChildren(loc),
      _sectionTitle(loc.helpAboutSection),
      ..._aboutChildren(loc),
      _sectionTitle(loc.helpSponsorSection),
      ..._sponsorChildren(loc),
    ],
  );

  /// 桌面端/宽屏：左侧菜单 + 右侧内容
  Widget _buildTwoColumn(AppLocalizations loc) => Row(
    children: [
      SizedBox(
        width: 220,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _menuTile(0, Icons.menu_book, loc.helpDocSection),
            _menuTile(1, Icons.info_outline, loc.helpAboutSection),
            _menuTile(2, Icons.favorite_border, loc.helpSponsorSection),
          ],
        ),
      ),
      const VerticalDivider(width: 1, color: Colors.white24),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          children: [
            _sectionTitle(_currentSectionTitle(loc)),
            ..._contentChildren(loc),
          ],
        ),
      ),
    ],
  );

  String _currentSectionTitle(AppLocalizations loc) => switch (_sectionIndex) {
    1 => loc.helpAboutSection,
    2 => loc.helpSponsorSection,
    _ => loc.helpDocSection,
  };

  List<Widget> _contentChildren(AppLocalizations loc) =>
      switch (_sectionIndex) {
        1 => _aboutChildren(loc),
        2 => _sponsorChildren(loc),
        _ => _docChildren(loc),
      };

  // ── 各分区内容 ──

  /// 说明文档：功能分组说明
  List<Widget> _docChildren(AppLocalizations loc) => [
    _groupTitle(loc.helpGroupPlay),
    _bullet(loc.helpPlayOrder),
    _bullet(loc.helpLoopAuto),
    _bullet(loc.helpPlayPause),
    _bullet(loc.helpGestures),
    _groupTitle(loc.helpGroupDisplay),
    _bullet(loc.helpFitMode),
    _bullet(loc.helpBackground),
    _bullet(loc.helpOrientation),
    _bullet(loc.helpZoomPan),
    _bullet(loc.helpWheel),
    _groupTitle(loc.helpGroupTransition),
    _bullet(loc.helpTransition),
    _bullet(loc.helpAnimDuration),
    _groupTitle(loc.helpGroupFullscreen),
    _bullet(loc.helpFullscreen),
    _bullet(loc.helpToolbar),
    _groupTitle(loc.helpGroupFolders),
    _bullet(loc.helpFolders),
    _bullet(loc.helpFormats),
    _bullet(loc.helpExclude),
    _bullet(loc.helpBrowse),
    _bullet(loc.helpInfoDisplay),
  ];

  /// 关于：版本信息 + GitHub 链接
  List<Widget> _aboutChildren(AppLocalizations loc) => [
    _infoRow(Icons.info_outline, loc.helpVersionLabel, appVersionLabel),
    _linkRow(Icons.code, loc.helpGitHub, HelpScreen.githubUrl),
  ];

  /// 赞助：简短说明 + 赞助页链接
  List<Widget> _sponsorChildren(AppLocalizations loc) => [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        loc.helpSponsorDesc,
        style: const TextStyle(fontSize: 14, color: Colors.white70),
      ),
    ),
    const SizedBox(height: 12),
    SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _openUrl(HelpScreen.sponsorUrl),
        icon: const Icon(Icons.favorite, size: 20),
        label: Text(loc.helpSponsorButton),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFe17055),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    ),
  ];

  // ── 基础组件 ──

  Widget _menuTile(int index, IconData icon, String title) => ListTile(
    selected: _sectionIndex == index,
    selectedTileColor: const Color(0xFF16213e),
    selectedColor: const Color(0xFFe94560),
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontSize: 14)),
    onTap: () => setState(() => _sectionIndex = index),
  );

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Color(0xFFe94560),
      ),
    ),
  );

  Widget _groupTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
    ),
  );

  Widget _bullet(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• ', style: TextStyle(color: Colors.grey)),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: Colors.white70),
          ),
        ),
      ],
    ),
  );

  Widget _infoRow(IconData icon, String label, String value) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: Colors.grey),
    title: Text(label, style: const TextStyle(fontSize: 14)),
    trailing: Text(
      value,
      style: const TextStyle(fontSize: 14, color: Colors.white70),
    ),
  );

  Widget _linkRow(IconData icon, String label, String url) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: Colors.blueAccent),
    title: Text(label, style: const TextStyle(fontSize: 14)),
    trailing: const Icon(Icons.open_in_new, size: 18, color: Colors.grey),
    onTap: () => _openUrl(url),
  );
}
