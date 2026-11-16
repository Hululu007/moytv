import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 霓虹主题测试：四套颜色值与用户原文逐值一致、逐套切主题泵主题
///
/// 设置页、新主题显示方案默认、霓虹卡片发光/倾斜/点卡/集数标签唯一。
/// 只写代码不运行，由父代理统一验证。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Color> gradientColors(AppThemeConfig config) =>
      (config.backgroundGradient! as LinearGradient).colors;

  test('紫蓝霓虹颜色值与原文 purpleBlueNeon 逐值一致（原文 5–34 行）', () {
    final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
    expect(config.themeName, '紫蓝霓虹');
    expect(gradientColors(config), const [
      Color(0xFF6A0572),
      Color(0xFF1A2980),
      Color(0xFF000000),
    ]);
    expect(config.primaryColor, const Color(0xFFE040FB));
    expect(config.secondaryColor, const Color(0xFF00BCD4));
    expect(config.accentColor, const Color(0xFFFF2EC6));
    expect(config.cardBorderColor, const Color(0xFF00E5FF));
    expect(config.glowColor, const Color(0xFF00BCD4));
    expect(config.glowBlur, 18);
    expect(config.textPrimary, Colors.white);
    expect(config.textSecondary, const Color(0xFFB3E5FC));
    expect(config.titleShadows, const [
      Shadow(color: Color(0xFFE040FB), blurRadius: 12),
      Shadow(color: Color(0xFF00BCD4), blurRadius: 12),
    ]);
    expect(config.subtitleShadows, const [
      Shadow(color: Color(0xFF00BCD4), blurRadius: 8),
    ]);
  });

  test('青绿赛博颜色值与原文 cyanCyberNeon 逐值一致（原文 36–65 行）', () {
    final config = AppThemeConfig.forTheme(AppThemeMode.cyanCyberNeon);
    expect(config.themeName, '青绿赛博');
    expect(gradientColors(config), const [
      Color(0xFF004D40),
      Color(0xFF001A1A),
      Color(0xFF000000),
    ]);
    expect(config.primaryColor, const Color(0xFF1DE9B6));
    expect(config.secondaryColor, const Color(0xFF00E676));
    expect(config.accentColor, const Color(0xFF76FF03));
    expect(config.cardBorderColor, const Color(0xFF1DE9B6));
    expect(config.glowColor, const Color(0xFF1DE9B6));
    expect(config.glowBlur, 22);
    expect(config.textPrimary, Colors.white);
    expect(config.textSecondary, const Color(0xFFB9F6CA));
    expect(config.titleShadows, const [
      Shadow(color: Color(0xFF1DE9B6), blurRadius: 14),
      Shadow(color: Color(0xFF00E676), blurRadius: 10),
    ]);
    expect(config.subtitleShadows, const [
      Shadow(color: Color(0xFF1DE9B6), blurRadius: 8),
    ]);
  });

  test('红黑霓虹颜色值与原文 redBlackNeon 逐值一致（原文 67–96 行）', () {
    final config = AppThemeConfig.forTheme(AppThemeMode.redBlackNeon);
    expect(config.themeName, '红黑霓虹');
    expect(gradientColors(config), const [
      Color(0xFF4A0000),
      Color(0xFF1A0000),
      Color(0xFF000000),
    ]);
    expect(config.primaryColor, const Color(0xFFFF1744));
    expect(config.secondaryColor, const Color(0xFFFF5252));
    expect(config.accentColor, const Color(0xFFFF8A80));
    expect(config.cardBorderColor, const Color(0xFFFF1744));
    expect(config.glowColor, const Color(0xFFFF1744));
    expect(config.glowBlur, 20);
    expect(config.textPrimary, Colors.white);
    expect(config.textSecondary, const Color(0xFFFFCDD2));
    expect(config.titleShadows, const [
      Shadow(color: Color(0xFFFF1744), blurRadius: 14),
      Shadow(color: Color(0xFFFF5252), blurRadius: 10),
    ]);
    expect(config.subtitleShadows, const [
      Shadow(color: Color(0xFFFF1744), blurRadius: 8),
    ]);
  });

  test('粉紫霓虹颜色值与原文 pinkPurpleNeon 逐值一致（原文 98–127 行）', () {
    final config = AppThemeConfig.forTheme(AppThemeMode.pinkPurpleNeon);
    expect(config.themeName, '粉紫霓虹');
    expect(gradientColors(config), const [
      Color(0xFFF06292),
      Color(0xFF4A148C),
      Color(0xFF1A0033),
    ]);
    expect(config.primaryColor, const Color(0xFFFF4081));
    expect(config.secondaryColor, const Color(0xFFE040FB));
    expect(config.accentColor, const Color(0xFFD500F9));
    expect(config.cardBorderColor, const Color(0xFFFF4081));
    expect(config.glowColor, const Color(0xFFE040FB));
    expect(config.glowBlur, 16);
    expect(config.textPrimary, Colors.white);
    expect(config.textSecondary, const Color(0xFFF8BBD0));
    expect(config.titleShadows, const [
      Shadow(color: Color(0xFFFF4081), blurRadius: 12),
      Shadow(color: Color(0xFFE040FB), blurRadius: 12),
    ]);
    expect(config.subtitleShadows, const [
      Shadow(color: Color(0xFFFF4081), blurRadius: 8),
    ]);
  });

  test('非霓虹主题新字段取默认值（无发光、无阴影）', () {
    final config = AppThemeConfig.forTheme(AppThemeMode.lightClean);
    expect(config.glowBlur, 0);
    expect(config.titleShadows, isEmpty);
    expect(config.subtitleShadows, isEmpty);
    expect(config.accentColor, config.primaryColor);
    expect(config.glowColor, config.primaryColor);
    expect(config.cardBorderColor, config.dividerColor);
  });

  testWidgets('逐套新主题切过去泵主题设置页不断言失败', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    const modes = {
      AppThemeMode.cyanCyberNeon: '青绿赛博',
      AppThemeMode.redBlackNeon: '红黑霓虹',
      AppThemeMode.pinkPurpleNeon: '粉紫霓虹',
    };
    for (final entry in modes.entries) {
      await store.setAppTheme(entry.key);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(entry.key).toThemeData(),
          home: ThemeSettingsScreen(store: store),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(entry.value), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  test('新主题显示方案默认全部内容+底部标签+普通列表', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    for (final mode in [
      AppThemeMode.cyanCyberNeon,
      AppThemeMode.redBlackNeon,
      AppThemeMode.pinkPurpleNeon,
    ]) {
      final scheme = store.displayScheme(mode);
      expect(scheme.contentTier, ContentTier.all);
      expect(scheme.navStyle, NavStyle.bottomTabs);
      expect(navStyleForTheme(mode), NavStyle.bottomTabs);
      expect(siteListStyleForTheme(mode), SiteListStyle.normal);
    }
  });

  BoxDecoration posterDecoration(WidgetTester tester) {
    final box = find.descendant(
      of: find.byType(NeonPoster),
      matching: find.byType(Container),
    );
    return tester.widget<Container>(box.first).decoration! as BoxDecoration;
  }

  Future<void> mountPoster(
    WidgetTester tester, {
    required AppThemeMode mode,
    double tiltAngle = 0,
    VoidCallback? onTap,
  }) async {
    const drama = Drama(
      id: 's1:1',
      source: 's1',
      title: '霓虹剧',
      cover: 'https://x.test/a.jpg',
      episodes: 12,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(mode).toThemeData(),
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 220,
            child: NeonPoster(
              cover: DramaCover(
                drama: drama,
                repository: FixtureRepository(),
                showEpisodeLabel: false,
              ),
              title: drama.title,
              subtitle: '共 12 集',
              tiltAngle: tiltAngle,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('霓虹卡片边框与发光取当前主题值', (tester) async {
    await mountPoster(tester, mode: AppThemeMode.cyanCyberNeon);
    final config = AppThemeConfig.forTheme(AppThemeMode.cyanCyberNeon);
    final decoration = posterDecoration(tester);
    expect(decoration.border?.top.color, config.cardBorderColor);
    expect(decoration.border?.top.width, 1.5);
    expect(decoration.boxShadow, hasLength(1));
    expect(
      decoration.boxShadow!.first.color,
      config.glowColor.withValues(alpha: 0.5),
    );
    expect(decoration.boxShadow!.first.blurRadius, config.glowBlur);
    // 副标题色与阴影取当前主题。
    final subtitle = tester.widget<Text>(find.text('共 12 集'));
    expect(subtitle.style!.color, config.textSecondary);
    expect(subtitle.style!.shadows, config.subtitleShadows);
  });

  testWidgets('霓虹卡片倾斜只在传角时出现', (tester) async {
    await mountPoster(
      tester,
      mode: AppThemeMode.purpleNeon,
      tiltAngle: 0.1,
    );
    expect(find.byType(NeonTilt), findsOneWidget);
    expect(
      tester.widget<NeonTilt>(find.byType(NeonTilt)).angle,
      0.1,
    );
    await mountPoster(tester, mode: AppThemeMode.purpleNeon);
    expect(find.byType(NeonTilt), findsNothing);
  });

  testWidgets('霓虹卡片点卡触发回调、集数标签只出现一次、无播放按钮', (
    tester,
  ) async {
    var taps = 0;
    await mountPoster(
      tester,
      mode: AppThemeMode.redBlackNeon,
      onTap: () => taps++,
    );
    // 封面集数标已压住（showEpisodeLabel:false），只剩副标题一处。
    expect(find.text('共 12 集'), findsOneWidget);
    expect(find.text('马上看'), findsNothing);
    expect(find.text('立即播放'), findsNothing);
    // 点卡片左上角：桩仓库的封面一律失败，卡片中心是失败重试钮，
    // 点中心只触发重试、不会触发卡片回调（既有行为）。
    final poster = find.byType(NeonPoster);
    await tester.tapAt(tester.getTopLeft(poster) + const Offset(20, 20));
    expect(taps, 1);
  });
}
