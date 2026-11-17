import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('XP 主题注册', () {
    test('XP 在主题表里，数量 13→14', () {
      expect(AppThemeMode.values, contains(AppThemeMode.xpWindows));
      expect(AppThemeMode.values.length, 14);
    });

    test('XP 配置：Luna 蓝主色、绿开始钮点缀、浅色底', () {
      final config = AppThemeConfig.forTheme(AppThemeMode.xpWindows);
      expect(config.themeName, 'XP');
      expect(config.primaryColor, const Color(0xFF245EDC));
      expect(config.secondaryColor, const Color(0xFF3F8CF3));
      expect(config.backgroundColor, const Color(0xFFECE9D8));
      expect(config.accentColor, const Color(0xFF3D9E3D));
      expect(config.isDark, isFalse);
      expect(config.brightness, Brightness.light);
      expect(config.navStyle, CategoryNavStyle.lightSidebar);
    });

    test('XP 与 Win7 外观严格区分', () {
      final xp = AppThemeConfig.forTheme(AppThemeMode.xpWindows);
      final win7 = AppThemeConfig.forTheme(AppThemeMode.win7);
      expect(xp.primaryColor, isNot(win7.primaryColor));
      expect(xp.backgroundColor, isNot(win7.backgroundColor));
      expect(xp.surfaceColor, isNot(win7.surfaceColor));
      expect(xp.brightness, isNot(win7.brightness));
    });

    test('XP 绑定普通列表样式与底部标签导航', () {
      expect(
        siteListStyleForTheme(AppThemeMode.xpWindows),
        SiteListStyle.normal,
      );
      expect(navStyleForTheme(AppThemeMode.xpWindows), NavStyle.bottomTabs);
    });

    test('XP 显示方案默认全部内容', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final scheme = store.displayScheme(AppThemeMode.xpWindows);
      expect(scheme.contentTier, ContentTier.all);
      expect(scheme.navStyle, NavStyle.bottomTabs);
    });

    test('默认主题仍是 Win7，XP 存值往返', () {
      expect(AppThemeMode.fromStorageValue(null), AppThemeMode.win7);
      expect(AppThemeMode.fromStorageValue(''), AppThemeMode.win7);
      expect(
        AppThemeMode.fromStorageValue('xpWindows'),
        AppThemeMode.xpWindows,
      );
      expect(AppThemeMode.xpWindows.storageValue, 'xpWindows');
      expect(
        AppThemeMode.fromStorageValue(AppThemeMode.xpWindows.storageValue),
        AppThemeMode.xpWindows,
      );
    });
  });
}
