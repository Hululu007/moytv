import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return LocalStore(await SharedPreferences.getInstance());
  }

  test('主题偏好经 LocalStore 往返，默认紫蓝霓虹', () async {
    final store = await localStore();
    expect(store.appTheme, AppThemeMode.purpleNeon);
    await store.setAppTheme(AppThemeMode.goldVip);
    expect(store.appTheme, AppThemeMode.goldVip);
    final restored = LocalStore(store.preferences);
    expect(restored.appTheme, AppThemeMode.goldVip);
    store.dispose();
    restored.dispose();
  });

  test('旧主题偏好迁移后不再残留', () async {
    final store = await localStore({
      'themeMode': 'dark',
      'themeModeStyle': 'pureDark',
      'themeStyle': 'neon',
      'themeAccent': 'blue',
      'themeBackground': 'gradient',
      'themeBackgroundImage': 'bg.jpg',
    });
    expect(store.hasLegacyThemeSettings, isTrue);
    // 旧值不影响新主题：仍是默认紫蓝霓虹。
    expect(store.appTheme, AppThemeMode.purpleNeon);
    await store.migrateLegacyThemeSettings();
    expect(store.hasLegacyThemeSettings, isFalse);
    final restored = LocalStore(store.preferences);
    expect(restored.hasLegacyThemeSettings, isFalse);
    expect(restored.appTheme, AppThemeMode.purpleNeon);
    store.dispose();
    restored.dispose();
  });

  test('没有旧值时迁移是空操作', () async {
    final store = await localStore();
    expect(store.hasLegacyThemeSettings, isFalse);
    await store.migrateLegacyThemeSettings();
    expect(store.appTheme, AppThemeMode.purpleNeon);
    store.dispose();
  });

  testWidgets('主题设置页列出 8 套主题，点选即时存盘', (tester) async {
    final store = await localStore();
    await tester.pumpWidget(
      MaterialApp(home: ThemeSettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
    for (final mode in AppThemeMode.values) {
      expect(
        find.byKey(ValueKey('app-theme-${mode.storageValue}')),
        findsOneWidget,
        reason: mode.name,
      );
    }
    expect(find.text('紫蓝霓虹'), findsOneWidget);
    expect(find.text('黑金VIP'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-theme-goldVip')));
    await tester.pumpAndSettle();
    expect(store.appTheme, AppThemeMode.goldVip);
    store.dispose();
  });

  testWidgets('恢复默认主题回到紫蓝霓虹', (tester) async {
    final store = await localStore();
    await store.setAppTheme(AppThemeMode.cyberBlue);
    await tester.pumpWidget(
      MaterialApp(home: ThemeSettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
    final resetButton = find.text('恢复默认主题');
    await tester.dragUntilVisible(
      resetButton,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(resetButton);
    await tester.pumpAndSettle();
    expect(store.appTheme, AppThemeMode.purpleNeon);
    store.dispose();
  });
}
