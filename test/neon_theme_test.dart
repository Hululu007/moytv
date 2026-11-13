import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_drawer.dart';
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
      // 顶栏跟主题底色，抽屉跟主题同色，而不是另一块纯色板
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
      appThemeNotifier.value = AppThemeMode.goldVip;
      expect(neonStyleActive, isFalse);
      appThemeNotifier.value = AppThemeMode.purpleNeon;
    });
  });

  group('抽屉跟着主题走', () {
    Future<void> pumpDrawer(WidgetTester tester, AppThemeMode mode) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(mode).toThemeData(),
          home: AppDrawer(
            zone: HomeZone.vod,
            currentVersion: '1.0.0',
            onZoneSelected: (_) {},
            onWatchRoom: () {},
            onTool: (_) {},
            onMinorProtectionChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('紫蓝霓虹下抽屉铺氛围光背景，底色透明', (tester) async {
      appThemeNotifier.value = AppThemeMode.purpleNeon;
      addTearDown(
        () => appThemeNotifier.value = AppThemeMode.purpleNeon,
      );
      await pumpDrawer(tester, AppThemeMode.purpleNeon);
      expect(find.byType(AppDrawer), findsOneWidget);
      expect(find.byKey(const ValueKey('drawer-neon')), findsOneWidget);
      expect(find.byType(NeonBackdrop), findsOneWidget);
      final drawer = tester.widget<Drawer>(
        find.byKey(const ValueKey('drawer-neon')),
      );
      expect(drawer.backgroundColor, Colors.transparent);
    });

    testWidgets('非霓虹主题仍是普通抽屉', (tester) async {
      appThemeNotifier.value = AppThemeMode.goldVip;
      addTearDown(
        () => appThemeNotifier.value = AppThemeMode.purpleNeon,
      );
      await pumpDrawer(tester, AppThemeMode.goldVip);
      expect(find.byKey(const ValueKey('drawer-neon')), findsNothing);
      expect(find.byType(NeonBackdrop), findsNothing);
    });
  });
}
