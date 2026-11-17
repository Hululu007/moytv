import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('14 套主题配置', () {
    test('名字与关键配色与用户文件一致', () {
      final expected = {
        AppThemeMode.purpleNeon: (
          '紫蓝霓虹',
          const Color(0xFFE040FB),
          const Color(0xFF00BCD4),
          const Color(0xFF14102A),
        ),
        AppThemeMode.lightClean: (
          '浅色清爽',
          const Color(0xFF2196F3),
          const Color(0xFF64B5F6),
          const Color(0xFFF7F9FC),
        ),
        AppThemeMode.goldVip: (
          '黑金VIP',
          const Color(0xFFFFC107),
          const Color(0xFF8D6E00),
          const Color(0xFF121212),
        ),
        AppThemeMode.cyberBlue: (
          '赛博蓝绿',
          const Color(0xFF00FFD5),
          const Color(0xFF00B4D8),
          const Color(0xFF051428),
        ),
        AppThemeMode.kidFamily: (
          '亲子儿童',
          const Color(0xFFFF7096),
          const Color(0xFFFFD166),
          const Color(0xFFFFF4F8),
        ),
        AppThemeMode.minimalCard: (
          '极简卡片',
          Colors.black,
          const Color(0xFFB00020),
          const Color(0xFFF5F5F5),
        ),
        AppThemeMode.retroFilm: (
          '复古胶片',
          const Color(0xFFC8894B),
          const Color(0xFF6F4E37),
          const Color(0xFF2B1F14),
        ),
        AppThemeMode.tvBigScreen: (
          '大屏TV',
          const Color(0xFF40C9FF),
          const Color(0xFF7B66FF),
          const Color(0xFF0A0E27),
        ),
        AppThemeMode.leftCategories: (
          '左侧分类',
          const Color(0xFF22D3EE),
          const Color(0xFFE847A2),
          const Color(0xFF120E2B),
        ),
        AppThemeMode.cyanCyberNeon: (
          '青绿赛博',
          const Color(0xFF1DE9B6),
          const Color(0xFF00E676),
          const Color(0xFF001A1A),
        ),
        AppThemeMode.redBlackNeon: (
          '红黑霓虹',
          const Color(0xFFFF1744),
          const Color(0xFFFF5252),
          const Color(0xFF1A0000),
        ),
        AppThemeMode.pinkPurpleNeon: (
          '粉紫霓虹',
          const Color(0xFFFF4081),
          const Color(0xFFE040FB),
          const Color(0xFF1A0033),
        ),
        AppThemeMode.win7: (
          'Win7',
          const Color(0xFF0078D4),
          const Color(0xFF1E88E5),
          const Color(0xFF002147),
        ),
      };
      for (final entry in expected.entries) {
        final config = AppThemeConfig.forTheme(entry.key);
        expect(config.themeName, entry.value.$1);
        expect(config.primaryColor, entry.value.$2);
        expect(config.secondaryColor, entry.value.$3);
        expect(config.backgroundColor, entry.value.$4);
      }
    });

    test('每套主题绑定一种侧边栏样式', () {
      const expected = {
        AppThemeMode.purpleNeon: CategoryNavStyle.darkSidebar,
        AppThemeMode.lightClean: CategoryNavStyle.lightSidebar,
        AppThemeMode.goldVip: CategoryNavStyle.goldSidebar,
        AppThemeMode.cyberBlue: CategoryNavStyle.cyberSidebar,
        AppThemeMode.kidFamily: CategoryNavStyle.colorBlockSidebar,
        AppThemeMode.minimalCard: CategoryNavStyle.miniIconSidebar,
        AppThemeMode.retroFilm: CategoryNavStyle.foldFilterSidebar,
        AppThemeMode.tvBigScreen: CategoryNavStyle.tvWideSidebar,
        AppThemeMode.leftCategories: CategoryNavStyle.leftCategorySidebar,
        AppThemeMode.cyanCyberNeon: CategoryNavStyle.cyberSidebar,
        AppThemeMode.redBlackNeon: CategoryNavStyle.darkSidebar,
        AppThemeMode.pinkPurpleNeon: CategoryNavStyle.colorBlockSidebar,
        AppThemeMode.win7: CategoryNavStyle.darkSidebar,
      };
      for (final entry in expected.entries) {
        expect(
          AppThemeConfig.forTheme(entry.key).navStyle,
          entry.value,
          reason: entry.key.name,
        );
      }
    });

    test('亮暗按主题自身底色定', () {
      expect(AppThemeConfig.forTheme(AppThemeMode.purpleNeon).isDark, isTrue);
      expect(AppThemeConfig.forTheme(AppThemeMode.lightClean).isDark, isFalse);
      expect(AppThemeConfig.forTheme(AppThemeMode.goldVip).isDark, isTrue);
      expect(AppThemeConfig.forTheme(AppThemeMode.cyberBlue).isDark, isTrue);
      expect(AppThemeConfig.forTheme(AppThemeMode.kidFamily).isDark, isFalse);
      expect(AppThemeConfig.forTheme(AppThemeMode.minimalCard).isDark, isFalse);
      expect(AppThemeConfig.forTheme(AppThemeMode.retroFilm).isDark, isTrue);
      expect(AppThemeConfig.forTheme(AppThemeMode.tvBigScreen).isDark, isTrue);
      expect(
        AppThemeConfig.forTheme(AppThemeMode.leftCategories).isDark,
        isTrue,
      );
      expect(
        AppThemeConfig.forTheme(AppThemeMode.cyanCyberNeon).isDark,
        isTrue,
      );
      expect(AppThemeConfig.forTheme(AppThemeMode.redBlackNeon).isDark, isTrue);
      expect(
        AppThemeConfig.forTheme(AppThemeMode.pinkPurpleNeon).isDark,
        isTrue,
      );
      expect(AppThemeConfig.forTheme(AppThemeMode.win7).isDark, isTrue);
    });
  });

  group('存储值', () {
    test('14 套主题存储值往返', () {
      for (final mode in AppThemeMode.values) {
        expect(
          AppThemeMode.fromStorageValue(mode.storageValue),
          mode,
          reason: mode.name,
        );
      }
    });

    test('未知或空存储值回落默认 Win7，已存偏好优先', () {
      expect(AppThemeMode.fromStorageValue(null), AppThemeMode.win7);
      expect(AppThemeMode.fromStorageValue(''), AppThemeMode.win7);
      expect(AppThemeMode.fromStorageValue('neon'), AppThemeMode.win7);
      expect(AppThemeMode.fromStorageValue('bogus'), AppThemeMode.win7);
      // 已存偏好不受默认影响：读到哪套就是哪套。
      expect(
        AppThemeMode.fromStorageValue('purpleNeon'),
        AppThemeMode.purpleNeon,
      );
      expect(AppThemeMode.fromStorageValue('goldVip'), AppThemeMode.goldVip);
    });
  });

  group('toThemeData', () {
    test('亮暗与底色跟随主题自身', () {
      for (final mode in AppThemeMode.values) {
        final config = AppThemeConfig.forTheme(mode);
        final theme = config.toThemeData();
        expect(
          theme.brightness,
          config.isDark ? Brightness.dark : Brightness.light,
          reason: mode.name,
        );
        expect(theme.scaffoldBackgroundColor, config.backgroundColor);
        expect(theme.colorScheme.primary, config.primaryColor);
        expect(theme.colorScheme.secondary, config.secondaryColor);
        expect(theme.colorScheme.surface, config.surfaceColor);
        expect(theme.colorScheme.onSurface, config.textPrimary);
        expect(theme.colorScheme.onSurfaceVariant, config.textSecondary);
        expect(theme.extensions[AppThemeConfig], same(config));
      }
    });

    test('顶栏与抽屉主题配置跟主题配色', () {
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      final theme = config.toThemeData();
      expect(theme.appBarTheme.backgroundColor, config.backgroundColor);
      expect(theme.drawerTheme.backgroundColor, config.surfaceColor);
    });
  });

  testWidgets('AppThemeConfig.of 在没有配置时回落 Win7', (tester) async {
    AppThemeConfig? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = AppThemeConfig.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen?.mode, AppThemeMode.win7);
  });
}
