import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';

void main() {
  group('Win7 主题注册', () {
    test('Win7 在主题表里，数量 12→13', () {
      expect(AppThemeMode.values, contains(AppThemeMode.win7));
      expect(AppThemeMode.values.length, 14);
    });

    test('Win7 配置：名与配色取设计稿精确值', () {
      final config = AppThemeConfig.forTheme(AppThemeMode.win7);
      expect(config.themeName, 'Win7');
      expect(config.primaryColor, const Color(0xFF0078D4));
      expect(config.secondaryColor, const Color(0xFF1E88E5));
      expect(config.backgroundColor, const Color(0xFF002147));
      expect(config.isDark, isTrue);
      expect(config.brightness, Brightness.dark);
    });

    test('Win7 绑定普通列表样式与底部标签导航', () {
      expect(siteListStyleForTheme(AppThemeMode.win7), SiteListStyle.normal);
      expect(navStyleForTheme(AppThemeMode.win7), NavStyle.bottomTabs);
    });

    test('默认主题断言：无偏好时 XP，有偏好时偏好优先', () {
      expect(AppThemeMode.fromStorageValue(null), AppThemeMode.xpWindows);
      expect(AppThemeMode.fromStorageValue(''), AppThemeMode.xpWindows);
      expect(AppThemeMode.fromStorageValue('win7'), AppThemeMode.win7);
      expect(
        AppThemeMode.fromStorageValue('xpWindows'),
        AppThemeMode.xpWindows,
      );
      expect(
        AppThemeMode.fromStorageValue('purpleNeon'),
        AppThemeMode.purpleNeon,
      );
      expect(
        AppThemeMode.fromStorageValue('lightClean'),
        AppThemeMode.lightClean,
      );
    });
  });
}
