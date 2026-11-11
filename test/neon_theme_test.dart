import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/theme_settings.dart';
import 'package:moyi/ui_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('霓虹主题覆盖', () {
    test('neon 风格把整套配色换成霓虹调色板', () {
      final theme = applyThemePreferences(AppTheme.dark, style: 'neon');
      expect(theme.scaffoldBackgroundColor, Neon.bg);
      expect(theme.colorScheme.primary, Neon.purple);
      expect(theme.colorScheme.tertiary, Neon.cyan);
      expect(theme.colorScheme.surface, Neon.surface);
      expect(theme.colorScheme.onSurface, Neon.text);
      // 顶栏透明，才能让氛围光透上来
      expect(theme.appBarTheme.backgroundColor, Colors.transparent);
      // 抽屉跟主题同色，而不是另一块纯色板
      expect(theme.drawerTheme.backgroundColor, Neon.surface);
      expect(theme.colorScheme.surfaceContainerHighest, isNot(Colors.white));
    });

    test('其它风格不受影响（仍是原配色）', () {
      final theme = applyThemePreferences(AppTheme.dark, style: 'deep');
      expect(theme.scaffoldBackgroundColor, isNot(Neon.bg));
    });

    test('亮色 + neon 也是紫色系，不是纯白', () {
      final theme = applyThemePreferences(AppTheme.light, style: 'neon');
      expect(theme.colorScheme.primary, isNot(Neon.purple));
      expect(theme.colorScheme.primary.b, greaterThan(0.5));
    });

    test('themeStyleNotifier 决定 neonStyleActive', () {
      themeStyleNotifier.value = '';
      expect(neonStyleActive, isFalse);
      themeStyleNotifier.value = 'neon';
      expect(neonStyleActive, isTrue);
      expect(neonStyleActive, isTrue);
      themeStyleNotifier.value = 'candy';
      expect(neonStyleActive, isFalse);
    });
  });

  group('抽屉跟着主题走', () {
    Future<void> pumpDrawer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: applyThemePreferences(AppTheme.dark, style: 'neon'),
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

    testWidgets('霓虹风格下抽屉铺氛围光背景，底色透明', (tester) async {
      themeStyleNotifier.value = 'neon';
      addTearDown(() => themeStyleNotifier.value = '');
      await pumpDrawer(tester);
      expect(find.byType(AppDrawer), findsOneWidget);
      expect(find.byKey(const ValueKey('drawer-neon')), findsOneWidget);
      expect(find.byType(NeonBackdrop), findsOneWidget);
      final drawer = tester.widget<Drawer>(
        find.byKey(const ValueKey('drawer-neon')),
      );
      expect(drawer.backgroundColor, Colors.transparent);
    });

    testWidgets('非霓虹风格仍是普通抽屉', (tester) async {
      themeStyleNotifier.value = 'deep';
      addTearDown(() => themeStyleNotifier.value = '');
      await pumpDrawer(tester);
      expect(find.byKey(const ValueKey('drawer-neon')), findsNothing);
      expect(find.byType(NeonBackdrop), findsNothing);
    });
  });
}
