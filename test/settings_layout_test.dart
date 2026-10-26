import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/screens/settings_screen.dart';

void main() {
  /// 以指定窗口宽度渲染设置页。
  ///
  /// 视口高度取足够大，避免 [ListView] 懒加载导致下方分组未被构建。
  Future<void> pumpSettings(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 2600);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
  }

  /// 页面主体里 [ListView] 的数量。
  ///
  /// 单栏与双栏都只有一个滚动列表（双栏共用同一个滚动位置），因此恒为 1。
  int listViewCount(WidgetTester tester) =>
      find.byType(ListView).evaluate().length;

  /// 左右两栏的定位键。
  Finder column(int index) =>
      find.byKey(ValueKey<String>('settings-column-$index'));

  /// 是否处于双栏布局。
  bool isTwoColumn(WidgetTester tester) =>
      find.byType(VerticalDivider).evaluate().isNotEmpty;

  testWidgets('窄屏时保持单栏（只有一条滚动列表、无分隔线）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, 600);

    expect(listViewCount(tester), 1);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(column(0), findsNothing);
    expect(column(1), findsNothing);
  });

  testWidgets('宽屏时分为左右两栏，但仍共用同一个滚动列表', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, 1400);

    // 两栏在同一个 ListView 内 → 只有一个滚动列表，同时滚动。
    expect(listViewCount(tester), 1);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(column(0), findsOneWidget);
    expect(column(1), findsOneWidget);
  });

  testWidgets('约 900 宽度是分栏阈值', (tester) async {
    addTearDown(tester.view.reset);

    // 刚好低于阈值 → 单栏
    await pumpSettings(tester, 880);
    expect(isTwoColumn(tester), isFalse);

    // 超过阈值 → 双栏
    await pumpSettings(tester, 1000);
    expect(isTwoColumn(tester), isTrue);
  });

  testWidgets('两种布局下所有分组标题都完整存在', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, 1400);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SettingsScreen)),
    );
    for (final title in [
      l10n.languageLabel,
      l10n.playSettings,
      l10n.videoDisplay,
      l10n.windowFullscreen,
      l10n.filesAndDirs,
      l10n.controlsLabel,
    ]) {
      expect(find.text(title), findsWidgets, reason: '缺少分组标题：$title');
    }
  });

  testWidgets('分组被真正分到左右两栏，且两栏等宽', (tester) async {
    addTearDown(tester.view.reset);
    await pumpSettings(tester, 1400);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SettingsScreen)),
    );

    final left = column(0);
    final right = column(1);
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);

    // 用「落在哪一栏」来断言，避免同一文案（如分组标题与下拉项）重复导致误判。
    Finder inColumn(Finder columnFinder, String text) =>
        find.descendant(of: columnFinder, matching: find.text(text));

    void expectOnlyIn(Finder columnFinder, Finder other, String title) {
      expect(
        inColumn(columnFinder, title),
        findsWidgets,
        reason: '$title 不在预期栏',
      );
      expect(inColumn(other, title), findsNothing, reason: '$title 不应出现在另一栏');
    }

    // 左栏（第 1 栏）应包含这些分组（「文件管理」按需求钉在左栏）。
    for (final title in [
      'languageLabel',
      'videoDisplay',
      'windowFullscreen',
      'filesAndDirs',
    ]) {
      expectOnlyIn(left, right, _titleOf(l10n, title));
    }
    // 右栏（第 2 栏）应包含这些分组。
    for (final title in ['playSettings', 'controlsLabel']) {
      expectOnlyIn(right, left, _titleOf(l10n, title));
    }

    // 两栏应是等宽的。
    final widths = [left, right]
        .map((f) => (f.evaluate().single.renderObject! as RenderBox).size.width)
        .toList();
    expect((widths[0] - widths[1]).abs(), lessThan(1.0));
  });
}

/// 按名字取分组标题文案，避免在用例里散落字符串。
String _titleOf(AppLocalizations l10n, String name) {
  switch (name) {
    case 'languageLabel':
      return l10n.languageLabel;
    case 'playSettings':
      return l10n.playSettings;
    case 'videoDisplay':
      return l10n.videoDisplay;
    case 'controlsLabel':
      return l10n.controlsLabel;
    case 'windowFullscreen':
      return l10n.windowFullscreen;
    case 'filesAndDirs':
      return l10n.filesAndDirs;
    default:
      throw ArgumentError('未知分组：$name');
  }
}
