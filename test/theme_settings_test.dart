import 'package:moyi/app_theme.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/theme_settings.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pure light mode forces white surfaces', () {
    final themed = applyThemePreferences(
      AppTheme.platformLight,
      modeStyle: 'pureLight',
    );
    expect(themed.brightness, Brightness.light);
    expect(themed.scaffoldBackgroundColor, Colors.white);
    expect(themed.colorScheme.surface, Colors.white);
    expect(themed.drawerTheme.backgroundColor, Colors.white);
  });

  test('pure dark mode forces black surfaces', () {
    final themed = applyThemePreferences(
      AppTheme.platformDark,
      modeStyle: 'pureDark',
    );
    expect(themed.brightness, Brightness.dark);
    expect(themed.scaffoldBackgroundColor, Colors.black);
    expect(themed.colorScheme.surface, Colors.black);
    expect(themed.drawerTheme.backgroundColor, Colors.black);
  });

  test('accent overrides primary and mode selects theme', () {
    final themed = applyThemePreferences(
      AppTheme.platformLight,
      accent: 'green',
    );
    expect(themed.colorScheme.primary, const Color(0xFF2E7D32));
    expect(themeModeFor('pureLight', 'system'), ThemeMode.light);
    expect(themeModeFor('pureDark', 'system'), ThemeMode.dark);
    expect(themeModeFor('', 'dark'), ThemeMode.dark);
    expect(themeModeFor('', 'system'), ThemeMode.system);
  });

  test('paper style uses serif titles, candy uses stadium buttons', () {
    final paper = applyThemePreferences(AppTheme.light, style: 'paper');
    expect(paper.textTheme.titleMedium?.fontFamily, 'serif');
    final candy = applyThemePreferences(AppTheme.light, style: 'candy');
    expect(candy.filledButtonTheme.style?.shape?.resolve({}), isA<StadiumBorder>());
  });

  test('custom accent id parses to its color and applies as primary', () {
    expect(themeAccentColor('custom:1E88E5'), const Color(0xFF1E88E5));
    expect(themeAccentColor('custom:ff0000'), const Color(0xFFFF0000));
    expect(themeAccentColor('custom:12345'), isNull);
    expect(themeAccentColor('custom:ZZZZZZ'), isNull);
    expect(themeAccentColor('custom:'), isNull);
    final themed = applyThemePreferences(
      AppTheme.platformLight,
      accent: 'custom:1E88E5',
    );
    expect(themed.colorScheme.primary, const Color(0xFF1E88E5));
  });

  test('custom accent id roundtrips through LocalStore and resets', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await store.setThemeAccent('custom:1E88E5');
    expect(store.themeAccent, 'custom:1E88E5');
    final restored = LocalStore(store.preferences);
    expect(restored.themeAccent, 'custom:1E88E5');
    await store.setThemeAccent('custom:XYZ');
    expect(store.themeAccent, 'custom:1E88E5');
    await store.resetThemeSettings();
    expect(store.themeAccent, '');
    store.dispose();
    restored.dispose();
  });

  testWidgets('custom accent tile opens picker and saves hex', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(home: ThemeSettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('custom-accent-tile'));
    await tester.dragUntilVisible(
      tile,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'FF0000');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(store.themeAccent, 'custom:FF0000');
    store.dispose();
  });

  test('theme prefs roundtrip through LocalStore', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.themeModeStyle, '');
    expect(store.themeBackground, 'theme');
    await store.setThemeModeStyle('pureDark');
    await store.setThemeStyle('glass');
    await store.setThemeAccent('blue');
    await store.setThemeBackground('gradient');
    expect(store.themeModeStyle, 'pureDark');
    expect(store.themeStyle, 'glass');
    expect(store.themeAccent, 'blue');
    expect(store.themeBackground, 'gradient');
    await store.resetThemeSettings();
    expect(store.themeModeStyle, '');
    expect(store.themeStyle, '');
    expect(store.themeAccent, '');
    expect(store.themeBackground, 'theme');
    store.dispose();
  });
}
