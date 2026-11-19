import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/ui_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('霓虹主题覆盖', () {
    test('紫蓝霓虹配置就是霓虹调色板', () {
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      final theme = config.toThemeData();
      expect(theme.scaffoldBackgroundColor, config.backgroundColor);
      expect(theme.colorScheme.primary, config.primaryColor);
      expect(theme.colorScheme.secondary, config.secondaryColor);
      expect(theme.colorScheme.surface, config.surfaceColor);
      expect(theme.colorScheme.onSurface, config.textPrimary);
      // 顶栏跟主题底色，抽屉主题（历史遗留配置项）跟主题同色，
      // 而不是另一块纯色板
      expect(theme.appBarTheme.backgroundColor, config.backgroundColor);
      expect(theme.drawerTheme.backgroundColor, config.surfaceColor);
      expect(theme.colorScheme.surfaceContainerHighest, isNot(Colors.white));
    });

    test('其它主题不受影响（仍是各自配色）', () {
      final theme = AppThemeConfig.forTheme(
        AppThemeMode.lightClean,
      ).toThemeData();
      expect(
        theme.scaffoldBackgroundColor,
        isNot(
          AppThemeConfig.forTheme(AppThemeMode.purpleNeon).backgroundColor,
        ),
      );
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF7F9FC));
    });

    test('appThemeNotifier 决定 neonStyleActive', () {
      appThemeNotifier.value = AppThemeMode.lightClean;
      expect(neonStyleActive, isFalse);
      appThemeNotifier.value = AppThemeMode.purpleNeon;
      expect(neonStyleActive, isTrue);
      appThemeNotifier.value = AppThemeMode.cyanCyberNeon;
      expect(neonStyleActive, isTrue);
      appThemeNotifier.value = AppThemeMode.redBlackNeon;
      expect(neonStyleActive, isTrue);
      appThemeNotifier.value = AppThemeMode.pinkPurpleNeon;
      expect(neonStyleActive, isTrue);
      appThemeNotifier.value = AppThemeMode.goldVip;
      expect(neonStyleActive, isFalse);
      appThemeNotifier.value = AppThemeMode.purpleNeon;
    });
  });

  group('胶囊栏跟着主题走', () {
    Future<void> pumpBar(WidgetTester tester, AppThemeMode mode) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(mode).toThemeData(),
          home: Scaffold(
            body: const SizedBox.shrink(),
            bottomNavigationBar: NeonCapsuleBar(
              entries: const [
                (LucideIcons.clapperboard, '片库'),
                (LucideIcons.tv, '直播'),
                (LucideIcons.headphones, '听书'),
                (LucideIcons.bookOpen, '阅读'),
                (LucideIcons.hardDrive, '网盘'),
                (LucideIcons.layoutGrid, '小程序'),
                (LucideIcons.user, '我的'),
              ],
              index: 0,
              onSelect: (_) {},
              onCenter: () {},
              centerAfter: 3,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('紫蓝霓虹下选中项用霓虹主色、未选中用次要文字色', (tester) async {
      appThemeNotifier.value = AppThemeMode.purpleNeon;
      addTearDown(() => appThemeNotifier.value = AppThemeMode.purpleNeon);
      await pumpBar(tester, AppThemeMode.purpleNeon);
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      expect(find.byType(NeonCapsuleBar), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('片库')).style?.color,
        config.primaryColor,
      );
      expect(
        tester.widget<Text>(find.text('直播')).style?.color,
        config.textSecondary,
      );
    });

    testWidgets('非霓虹主题用各自配色、同一胶囊结构', (tester) async {
      appThemeNotifier.value = AppThemeMode.goldVip;
      addTearDown(() => appThemeNotifier.value = AppThemeMode.purpleNeon);
      await pumpBar(tester, AppThemeMode.goldVip);
      final config = AppThemeConfig.forTheme(AppThemeMode.goldVip);
      expect(find.byType(NeonCapsuleBar), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('片库')).style?.color,
        config.primaryColor,
      );
      expect(
        tester.widget<Text>(find.text('直播')).style?.color,
        config.textSecondary,
      );
      expect(
        config.primaryColor,
        isNot(
          AppThemeConfig.forTheme(AppThemeMode.purpleNeon).primaryColor,
        ),
      );
    });
  });
}
