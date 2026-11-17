import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'liquid_glass.dart';

/// 全局主题：14 套固定主题（用户 2026-11-13 发来的代码定版 8 套，
/// 2026-11-14 新增第 9 套“左侧分类”，同日新增霓虹三套，2026-11-16
/// 新增第 13 套 Win7 与第 14 套 XP；名与配色均为暂定、用户可改；紫蓝霓虹配色取
/// 用户发的霓虹定义精确值）。
///
/// 配色与名字与用户文件逐字一致；每套主题绑定一种分类侧边栏样式。
/// 亮暗由各主题自身底色决定，不再跟随系统、不再套旧的 light/dark 两套。
/// 默认主题是 Win7（用户 2026-11-16 令）：读不到已存偏好时回落 Win7，
/// 已存偏好不受影响。
enum AppThemeMode {
  purpleNeon,
  lightClean,
  goldVip,
  cyberBlue,
  kidFamily,
  minimalCard,
  retroFilm,
  tvBigScreen,
  leftCategories,
  cyanCyberNeon,
  redBlackNeon,
  pinkPurpleNeon,
  win7,
  xpWindows;

  String get storageValue => name;

  static AppThemeMode fromStorageValue(String? value) =>
      AppThemeMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => AppThemeMode.win7,
      );
}

/// 导航样式：抽屉导航（默认）或底部标签导航（LwLive 式 5 Tab 底栏）。
enum NavStyle {
  drawer,
  bottomTabs;

  String get storageValue => name;

  String get label => switch (this) {
    NavStyle.drawer => '抽屉',
    NavStyle.bottomTabs => '底部标签',
  };

  static NavStyle fromStorageValue(String? value) => NavStyle.values.firstWhere(
    (style) => style.name == value,
    orElse: () => NavStyle.drawer,
  );
}

/// 内容档：主题绑定的内容过滤（第三阶段生效；第二阶段只存取、不过滤）。
enum ContentTier {
  all,
  manhua,
  liveAction,
  adult;

  String get storageValue => name;

  String get label => switch (this) {
    ContentTier.all => '全部内容',
    ContentTier.manhua => '漫剧',
    ContentTier.liveAction => '真人剧',
    ContentTier.adult => '成人视频',
  };

  static ContentTier fromStorageValue(String? value) => ContentTier.values
      .firstWhere((tier) => tier.name == value, orElse: () => ContentTier.all);
}

/// 主题绑定的显示方案：导航样式 + 内容档。切主题时四件一起变
/// （导航、分类、内容、列表样式），其中导航样式与列表样式是固定映射
/// （见 [navStyleForTheme] 与 [siteListStyleForTheme]），不存偏好、
/// 不设开关；只有内容档由用户在主题卡片上改、按主题存取。
///
/// 存储值格式为 `导航样式:内容档`（如 `bottomTabs:manhua`）；导航段是
/// 历史遗留，解析时忽略、只取内容档（导航样式只取主题固定值），只写
/// 导航样式的旧值（如 `drawer`）内容档回落全部内容；非法值整体回默认。
class ThemeDisplayScheme {
  const ThemeDisplayScheme({
    this.navStyle = NavStyle.bottomTabs,
    this.contentTier = ContentTier.all,
  });

  const ThemeDisplayScheme.defaults() : this();

  final NavStyle navStyle;
  final ContentTier contentTier;

  String get storageValue => '${navStyle.name}:${contentTier.name}';

  static ThemeDisplayScheme fromStorageValue(String? value) {
    if (value == null || value.isEmpty) {
      return const ThemeDisplayScheme.defaults();
    }
    final parts = value.split(':');
    // 导航段是历史遗留：导航样式自 2026-11-14 起只取主题固定值，
    // 这里忽略存值里的导航段、只取内容档，旧值绝不崩。生效的导航
    // 样式以 LocalStore.displayScheme 叠加 navStyleForTheme 为准。
    return ThemeDisplayScheme(
      navStyle: NavStyle.drawer,
      contentTier: parts.length > 1
          ? ContentTier.fromStorageValue(parts[1])
          : ContentTier.all,
    );
  }

  ThemeDisplayScheme copyWith({NavStyle? navStyle, ContentTier? contentTier}) =>
      ThemeDisplayScheme(
        navStyle: navStyle ?? this.navStyle,
        contentTier: contentTier ?? this.contentTier,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemeDisplayScheme &&
      other.navStyle == navStyle &&
      other.contentTier == contentTier;

  @override
  int get hashCode => Object.hash(navStyle, contentTier);
}

/// 站点列表样式：普通列表，或 3D 方块列（一个站点一个可拖动旋转的方块）。
enum SiteListStyle { normal, cube }

/// 列表样式固定映射：紫蓝霓虹主题 = 3D 方块，其余主题 = 普通。
/// 固定值只随主题切换一起变，不存偏好、不在主题设置里单设此项。
SiteListStyle siteListStyleForTheme(AppThemeMode mode) => switch (mode) {
  AppThemeMode.purpleNeon => SiteListStyle.cube,
  AppThemeMode.lightClean => SiteListStyle.normal,
  AppThemeMode.goldVip => SiteListStyle.normal,
  AppThemeMode.cyberBlue => SiteListStyle.normal,
  AppThemeMode.kidFamily => SiteListStyle.normal,
  AppThemeMode.minimalCard => SiteListStyle.normal,
  AppThemeMode.retroFilm => SiteListStyle.normal,
  AppThemeMode.tvBigScreen => SiteListStyle.normal,
  AppThemeMode.leftCategories => SiteListStyle.normal,
  AppThemeMode.cyanCyberNeon => SiteListStyle.normal,
  AppThemeMode.redBlackNeon => SiteListStyle.normal,
  AppThemeMode.pinkPurpleNeon => SiteListStyle.normal,
  AppThemeMode.win7 => SiteListStyle.normal,
  AppThemeMode.xpWindows => SiteListStyle.normal,
};

/// 导航样式固定映射：全部 14 套主题一律底部标签栏（霓虹胶囊壳；
/// Win7 与 XP 主题下首页外壳换成桌面 + 任务栏，胶囊栏不渲染，见 home_screen）。
///
/// 用户 2026-11-15 21:14 令：模仿蚂蚁影视的抽屉那套不用了（小退总
/// 丢首页），全部主题改底部标签栏，以霓虹那套 UI 为准先做；抽屉已拆，
/// 导航只随主题变、不另设开关。用户已存的各主题导航偏好（存值里的
/// 导航段）自此被固定值覆盖，只剩内容档继续按存值走。NavStyle.drawer
/// 只剩解析旧存值的占位作用，不再对应任何界面。
NavStyle navStyleForTheme(AppThemeMode mode) => switch (mode) {
  AppThemeMode.purpleNeon => NavStyle.bottomTabs,
  AppThemeMode.lightClean => NavStyle.bottomTabs,
  AppThemeMode.goldVip => NavStyle.bottomTabs,
  AppThemeMode.cyberBlue => NavStyle.bottomTabs,
  AppThemeMode.kidFamily => NavStyle.bottomTabs,
  AppThemeMode.minimalCard => NavStyle.bottomTabs,
  AppThemeMode.retroFilm => NavStyle.bottomTabs,
  AppThemeMode.tvBigScreen => NavStyle.bottomTabs,
  AppThemeMode.leftCategories => NavStyle.bottomTabs,
  AppThemeMode.cyanCyberNeon => NavStyle.bottomTabs,
  AppThemeMode.redBlackNeon => NavStyle.bottomTabs,
  AppThemeMode.pinkPurpleNeon => NavStyle.bottomTabs,
  AppThemeMode.win7 => NavStyle.bottomTabs,
  AppThemeMode.xpWindows => NavStyle.bottomTabs,
};

enum CategoryNavStyle {
  darkSidebar,
  colorBlockSidebar,
  miniIconSidebar,
  foldFilterSidebar,
  lightSidebar,
  goldSidebar,
  cyberSidebar,
  tvWideSidebar,
  leftCategorySidebar,
}

class AppThemeConfig extends ThemeExtension<AppThemeConfig> {
  const AppThemeConfig({
    required this.mode,
    required this.themeName,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
    required this.surfaceColor,
    required this.textPrimary,
    required this.textSecondary,
    required this.dividerColor,
    required this.selectedBg,
    required this.selectedText,
    required this.unselectedBg,
    required this.unselectedText,
    this.backgroundGradient,
    this.selectedGradient,
    required this.navStyle,
    // 霓虹字段（用户 2026-11-14 发来的 NeonTheme 定义所有，见字段映射）：
    // 非霓虹主题取中性默认值（点缀/发光取主色、边框取分隔色、
    // 发光半径 0、无标题阴影），霓虹四套取原文精确值。
    required this.accentColor,
    required this.cardBorderColor,
    required this.glowColor,
    required this.glowBlur,
    required this.titleShadows,
    required this.subtitleShadows,
  });

  final AppThemeMode mode;
  final String themeName;

  final Color primaryColor;
  final Color secondaryColor;
  final Color backgroundColor;
  final Color surfaceColor;
  final Color textPrimary;
  final Color textSecondary;
  final Color dividerColor;
  final Color selectedBg;
  final Color selectedText;
  final Color unselectedBg;
  final Color unselectedText;

  final Gradient? backgroundGradient;
  final Gradient? selectedGradient;

  final CategoryNavStyle navStyle;

  /// 点缀色（NeonTheme.accent）：霓虹高亮点缀。
  final Color accentColor;

  /// 卡片边框色（NeonTheme.cardBorder）：霓虹卡片发光边框。
  final Color cardBorderColor;

  /// 发光色（NeonTheme.glowColor）与发光半径（NeonTheme.glowBlur）。
  final Color glowColor;
  final double glowBlur;

  /// 标题/副标题发光阴影（NeonTheme.titleStyle/subStyle 的 shadows；
  /// 字号字重不进配置，沿用 App 全局 12px 字约定，颜色进
  /// textPrimary/textSecondary）。
  final List<Shadow> titleShadows;
  final List<Shadow> subtitleShadows;

  /// 亮暗由底色定：浅色清爽 / 亲子儿童 / 极简卡片 / XP 是浅底，其余是深底。
  Brightness get brightness => switch (mode) {
    AppThemeMode.lightClean ||
    AppThemeMode.kidFamily ||
    AppThemeMode.minimalCard ||
    AppThemeMode.xpWindows => Brightness.light,
    _ => Brightness.dark,
  };

  bool get isDark => brightness == Brightness.dark;

  static AppThemeConfig of(BuildContext context) =>
      Theme.of(context).extension<AppThemeConfig>() ??
      AppThemeConfig.forTheme(AppThemeMode.win7);

  factory AppThemeConfig.forTheme(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.purpleNeon:
        // 配色取用户发的 purpleBlueNeon 定义精确值（原文 5–34 行）；
        // NeonTheme 没有的纯色底/面色/选中色沿用旧值，选中色跟新主色。
        return AppThemeConfig(
          mode: mode,
          themeName: '紫蓝霓虹',
          primaryColor: Color(0xFFE040FB),
          secondaryColor: Color(0xFF00BCD4),
          backgroundColor: Color(0xFF14102A),
          surfaceColor: Color(0xFF1F1A3C),
          textPrimary: Colors.white,
          textSecondary: Color(0xFFB3E5FC),
          dividerColor: Colors.white12,
          selectedBg: Color(0xFFE040FB),
          selectedText: Colors.white,
          unselectedBg: Colors.white12,
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF6A0572), Color(0xFF1A2980), Color(0xFF000000)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFE040FB), Color(0xFF00BCD4)],
          ),
          navStyle: CategoryNavStyle.darkSidebar,
          accentColor: Color(0xFFFF2EC6),
          cardBorderColor: Color(0xFF00E5FF),
          glowColor: Color(0xFF00BCD4),
          glowBlur: 18,
          titleShadows: const [
            Shadow(color: Color(0xFFE040FB), blurRadius: 12),
            Shadow(color: Color(0xFF00BCD4), blurRadius: 12),
          ],
          subtitleShadows: const [
            Shadow(color: Color(0xFF00BCD4), blurRadius: 8),
          ],
        );

      case AppThemeMode.lightClean:
        return AppThemeConfig(
          mode: mode,
          themeName: '浅色清爽',
          primaryColor: Color(0xFF2196F3),
          secondaryColor: Color(0xFF64B5F6),
          backgroundColor: Color(0xFFF7F9FC),
          surfaceColor: Colors.white,
          textPrimary: Color(0xFF1A1A1A),
          textSecondary: Color(0xFF757575),
          dividerColor: Color(0xFFEEEEEE),
          selectedBg: Color(0xFF2196F3),
          selectedText: Colors.white,
          unselectedBg: Color(0xFFF1F5F9),
          unselectedText: Color(0xFF616161),
          navStyle: CategoryNavStyle.lightSidebar,
          accentColor: Color(0xFF2196F3),
          cardBorderColor: Color(0xFFEEEEEE),
          glowColor: Color(0xFF2196F3),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.goldVip:
        return AppThemeConfig(
          mode: mode,
          themeName: '黑金VIP',
          primaryColor: Color(0xFFFFC107),
          secondaryColor: Color(0xFF8D6E00),
          backgroundColor: Color(0xFF121212),
          surfaceColor: Color(0xFF1E1E1E),
          textPrimary: Color(0xFFFFF8E1),
          textSecondary: Color(0xFFBFA570),
          dividerColor: Colors.white12,
          selectedBg: Color(0xFFFFC107),
          selectedText: Colors.black,
          unselectedBg: Color(0xFF2C2C2C),
          unselectedText: Color(0xFFBFA570),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF121212), Color(0xFF2C2416)],
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFFFC107), Color(0xFF8D6E00)],
          ),
          navStyle: CategoryNavStyle.goldSidebar,
          accentColor: Color(0xFFFFC107),
          cardBorderColor: Colors.white12,
          glowColor: Color(0xFFFFC107),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.cyberBlue:
        return AppThemeConfig(
          mode: mode,
          themeName: '赛博蓝绿',
          primaryColor: Color(0xFF00FFD5),
          secondaryColor: Color(0xFF00B4D8),
          backgroundColor: Color(0xFF051428),
          surfaceColor: Color(0xFF0B2545),
          textPrimary: Colors.white,
          textSecondary: Colors.white70,
          // 与原文 Color(0xFF00FFD5).withOpacity(0.2) 同值，写成常量。
          dividerColor: Color(0x3300FFD5),
          selectedBg: Color(0xFF00FFD5),
          selectedText: Colors.black,
          unselectedBg: Color(0xFF0B2545),
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF051428), Color(0xFF003566)],
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF00FFD5), Color(0xFF00B4D8)],
          ),
          navStyle: CategoryNavStyle.cyberSidebar,
          accentColor: Color(0xFF00FFD5),
          cardBorderColor: Color(0x3300FFD5),
          glowColor: Color(0xFF00FFD5),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.kidFamily:
        return AppThemeConfig(
          mode: mode,
          themeName: '亲子儿童',
          primaryColor: Color(0xFFFF7096),
          secondaryColor: Color(0xFFFFD166),
          backgroundColor: Color(0xFFFFF4F8),
          surfaceColor: Colors.white,
          textPrimary: Color(0xFF333333),
          textSecondary: Color(0xFF777777),
          dividerColor: Color(0xFFFFE4F0),
          selectedBg: Color(0xFFFF7096),
          selectedText: Colors.white,
          unselectedBg: Color(0xFFFFE4F0),
          unselectedText: Color(0xFF777777),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFFFFF4F8), Color(0xFFE4F7FF)],
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFFF7096), Color(0xFFFFD166)],
          ),
          navStyle: CategoryNavStyle.colorBlockSidebar,
          accentColor: Color(0xFFFF7096),
          cardBorderColor: Color(0xFFFFE4F0),
          glowColor: Color(0xFFFF7096),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.minimalCard:
        return AppThemeConfig(
          mode: mode,
          themeName: '极简卡片',
          primaryColor: Colors.black,
          secondaryColor: Color(0xFFB00020),
          backgroundColor: Color(0xFFF5F5F5),
          surfaceColor: Colors.white,
          textPrimary: Colors.black87,
          textSecondary: Colors.black54,
          dividerColor: Color(0xFFEEEEEE),
          selectedBg: Colors.black,
          selectedText: Colors.white,
          unselectedBg: Color(0xFFFAFAFA),
          unselectedText: Colors.black54,
          navStyle: CategoryNavStyle.miniIconSidebar,
          accentColor: Colors.black,
          cardBorderColor: Color(0xFFEEEEEE),
          glowColor: Colors.black,
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.retroFilm:
        return AppThemeConfig(
          mode: mode,
          themeName: '复古胶片',
          primaryColor: Color(0xFFC8894B),
          secondaryColor: Color(0xFF6F4E37),
          backgroundColor: Color(0xFF2B1F14),
          surfaceColor: Color(0xFF3A2A1C),
          textPrimary: Color(0xFFF5E6D3),
          textSecondary: Color(0xFFC9B896),
          dividerColor: Color(0xFF6F4E37),
          selectedBg: Color(0xFFC8894B),
          selectedText: Colors.black,
          unselectedBg: Color(0xFF3A2A1C),
          unselectedText: Color(0xFFC9B896),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF2B1F14), Color(0xFF4A3520)],
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFC8894B), Color(0xFF6F4E37)],
          ),
          navStyle: CategoryNavStyle.foldFilterSidebar,
          accentColor: Color(0xFFC8894B),
          cardBorderColor: Color(0xFF6F4E37),
          glowColor: Color(0xFFC8894B),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      case AppThemeMode.tvBigScreen:
        return AppThemeConfig(
          mode: mode,
          themeName: '大屏TV',
          primaryColor: Color(0xFF40C9FF),
          secondaryColor: Color(0xFF7B66FF),
          backgroundColor: Color(0xFF0A0E27),
          surfaceColor: Color(0xFF141A3A),
          textPrimary: Colors.white,
          textSecondary: Colors.white70,
          dividerColor: Colors.white12,
          selectedBg: Color(0xFF40C9FF),
          selectedText: Colors.black,
          unselectedBg: Color(0xFF141A3A),
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF0A0E27), Color(0xFF141A3A)],
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF40C9FF), Color(0xFF7B66FF)],
          ),
          navStyle: CategoryNavStyle.tvWideSidebar,
          accentColor: Color(0xFF40C9FF),
          cardBorderColor: Colors.white12,
          glowColor: Color(0xFF40C9FF),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      // 第 9 套“左侧分类”：暂定配色、用户可改。骨架取紫蓝霓虹的深色
      // 底（深紫底 + 白字），主色改青蓝、辅色留霓虹粉，与效果图的
      // 紫蓝底 + 青粉霓虹光一致；亮暗走通配分支（深色）。
      case AppThemeMode.leftCategories:
        return AppThemeConfig(
          mode: mode,
          themeName: '左侧分类',
          primaryColor: Color(0xFF22D3EE),
          secondaryColor: Color(0xFFE847A2),
          backgroundColor: Color(0xFF120E2B),
          surfaceColor: Color(0xFF1E1838),
          textPrimary: Colors.white,
          textSecondary: Colors.white70,
          dividerColor: Colors.white12,
          selectedBg: Color(0xFF22D3EE),
          selectedText: Colors.black,
          unselectedBg: Colors.white12,
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF2A1B5E), Color(0xFF0E3A5C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF22D3EE), Color(0xFFE847A2)],
          ),
          navStyle: CategoryNavStyle.leftCategorySidebar,
          accentColor: Color(0xFF22D3EE),
          cardBorderColor: Colors.white12,
          glowColor: Color(0xFF22D3EE),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      // 青绿赛博：颜色取用户发的 cyanCyberNeon 定义精确值（原文 36–65 行）。
      // 纯色底/面色/选中色原文没有，按渐变中间色派生（已注明），选中色跟主色。
      case AppThemeMode.cyanCyberNeon:
        return AppThemeConfig(
          mode: mode,
          themeName: '青绿赛博',
          primaryColor: Color(0xFF1DE9B6),
          secondaryColor: Color(0xFF00E676),
          backgroundColor: Color(0xFF001A1A),
          surfaceColor: Color(0xFF0B2B25),
          textPrimary: Colors.white,
          textSecondary: Color(0xFFB9F6CA),
          dividerColor: Colors.white12,
          selectedBg: Color(0xFF1DE9B6),
          selectedText: Colors.black,
          unselectedBg: Colors.white12,
          unselectedText: Color(0xFFB9F6CA),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF004D40), Color(0xFF001A1A), Color(0xFF000000)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF1DE9B6), Color(0xFF00E676)],
          ),
          navStyle: CategoryNavStyle.cyberSidebar,
          accentColor: Color(0xFF76FF03),
          cardBorderColor: Color(0xFF1DE9B6),
          glowColor: Color(0xFF1DE9B6),
          glowBlur: 22,
          titleShadows: const [
            Shadow(color: Color(0xFF1DE9B6), blurRadius: 14),
            Shadow(color: Color(0xFF00E676), blurRadius: 10),
          ],
          subtitleShadows: const [
            Shadow(color: Color(0xFF1DE9B6), blurRadius: 8),
          ],
        );

      // 红黑霓虹：颜色取用户发的 redBlackNeon 定义精确值（原文 67–96 行）。
      case AppThemeMode.redBlackNeon:
        return AppThemeConfig(
          mode: mode,
          themeName: '红黑霓虹',
          primaryColor: Color(0xFFFF1744),
          secondaryColor: Color(0xFFFF5252),
          backgroundColor: Color(0xFF1A0000),
          surfaceColor: Color(0xFF2B0B0B),
          textPrimary: Colors.white,
          textSecondary: Color(0xFFFFCDD2),
          dividerColor: Colors.white12,
          selectedBg: Color(0xFFFF1744),
          selectedText: Colors.white,
          unselectedBg: Colors.white12,
          unselectedText: Color(0xFFFFCDD2),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF4A0000), Color(0xFF1A0000), Color(0xFF000000)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFFF1744), Color(0xFFFF5252)],
          ),
          navStyle: CategoryNavStyle.darkSidebar,
          accentColor: Color(0xFFFF8A80),
          cardBorderColor: Color(0xFFFF1744),
          glowColor: Color(0xFFFF1744),
          glowBlur: 20,
          titleShadows: const [
            Shadow(color: Color(0xFFFF1744), blurRadius: 14),
            Shadow(color: Color(0xFFFF5252), blurRadius: 10),
          ],
          subtitleShadows: const [
            Shadow(color: Color(0xFFFF1744), blurRadius: 8),
          ],
        );

      // 粉紫霓虹：颜色取用户发的 pinkPurpleNeon 定义精确值（原文 98–127 行）。
      case AppThemeMode.pinkPurpleNeon:
        return AppThemeConfig(
          mode: mode,
          themeName: '粉紫霓虹',
          primaryColor: Color(0xFFFF4081),
          secondaryColor: Color(0xFFE040FB),
          backgroundColor: Color(0xFF1A0033),
          surfaceColor: Color(0xFF2A0A4A),
          textPrimary: Colors.white,
          textSecondary: Color(0xFFF8BBD0),
          dividerColor: Colors.white12,
          selectedBg: Color(0xFFFF4081),
          selectedText: Colors.white,
          unselectedBg: Colors.white12,
          unselectedText: Color(0xFFF8BBD0),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFFF06292), Color(0xFF4A148C), Color(0xFF1A0033)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFFF4081), Color(0xFFE040FB)],
          ),
          navStyle: CategoryNavStyle.colorBlockSidebar,
          accentColor: Color(0xFFD500F9),
          cardBorderColor: Color(0xFFFF4081),
          glowColor: Color(0xFFE040FB),
          glowBlur: 16,
          titleShadows: const [
            Shadow(color: Color(0xFFFF4081), blurRadius: 12),
            Shadow(color: Color(0xFFE040FB), blurRadius: 12),
          ],
          subtitleShadows: const [
            Shadow(color: Color(0xFFFF4081), blurRadius: 8),
          ],
        );

      // 第 13 套 Win7：配色取用户 2026-11-16 发来的桌面设计稿精确值
      // （墙纸渐变 0F4C81→1E88E5→002147、开始钮蓝 0078D4、任务栏 /
      // 菜单深灰）；桌面本身由 win7_desktop.dart 画，这里只定全应用
      // 通用的 Material 配色（窗口内各区沿用各自界面，底色跟这套）。
      case AppThemeMode.win7:
        return AppThemeConfig(
          mode: mode,
          themeName: 'Win7',
          primaryColor: Color(0xFF0078D4),
          secondaryColor: Color(0xFF1E88E5),
          backgroundColor: Color(0xFF002147),
          surfaceColor: Color(0xFF202020),
          textPrimary: Colors.white,
          textSecondary: Colors.white70,
          dividerColor: Colors.white12,
          selectedBg: Color(0xFF0078D4),
          selectedText: Colors.white,
          unselectedBg: Colors.white12,
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF0F4C81), Color(0xFF1E88E5), Color(0xFF002147)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF0078D4), Color(0xFF1E88E5)],
          ),
          navStyle: CategoryNavStyle.darkSidebar,
          accentColor: Color(0xFF0078D4),
          cardBorderColor: Colors.white12,
          glowColor: Color(0xFF0078D4),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );

      // 第 14 套 XP：Luna 蓝主色、绿色开始钮点缀、浅色底；外观与
      // Win7 严格区分（用户 2026-11-16 令“win7是win7，xp系统你应该
      // 知道”）：桌面是用户发的绿色山丘墙纸图（assets/xp_wallpaper.jpg），
      // 这里只定全应用通用的 Material 配色（窗口内各区沿用各自界面）。
      case AppThemeMode.xpWindows:
        return AppThemeConfig(
          mode: mode,
          themeName: 'XP',
          primaryColor: Color(0xFF245EDC),
          secondaryColor: Color(0xFF3F8CF3),
          backgroundColor: Color(0xFFECE9D8),
          surfaceColor: Colors.white,
          textPrimary: Color(0xFF1A1A1A),
          textSecondary: Color(0xFF4A4A4A),
          dividerColor: Color(0xFFD4D0C8),
          selectedBg: Color(0xFF245EDC),
          selectedText: Colors.white,
          unselectedBg: Color(0xFFF1F1EA),
          unselectedText: Color(0xFF4A4A4A),
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF5A7EDC), Color(0xFF245EDC)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFF3F8CF3), Color(0xFF245EDC)],
          ),
          navStyle: CategoryNavStyle.lightSidebar,
          accentColor: Color(0xFF3D9E3D),
          cardBorderColor: Color(0xFFD4D0C8),
          glowColor: Color(0xFF245EDC),
          glowBlur: 0,
          titleShadows: const [],
          subtitleShadows: const [],
        );
    }
  }

  /// 从本配置派生整套 Material 主题：配色全部取自配置，形状与字号
  /// 沿用 App 既有约定（12px 字、圆角卡片、胶囊按钮），两平台同一套。
  ThemeData toThemeData() {
    final dark = isDark;
    final platform = defaultTargetPlatform;
    final scheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: brightness,
      primary: primaryColor,
      onPrimary: selectedText,
      primaryContainer: Color.lerp(
        primaryColor,
        backgroundColor,
        dark ? 0.72 : 0.82,
      )!,
      onPrimaryContainer: Color.lerp(
        primaryColor,
        dark ? Colors.white : Colors.black,
        dark ? 0.82 : 0.35,
      )!,
      secondary: secondaryColor,
      onSecondary: selectedText,
      secondaryContainer: Color.lerp(
        secondaryColor,
        backgroundColor,
        dark ? 0.72 : 0.82,
      )!,
      onSecondaryContainer: Color.lerp(
        secondaryColor,
        dark ? Colors.white : Colors.black,
        dark ? 0.82 : 0.35,
      )!,
      tertiary: secondaryColor,
      onTertiary: selectedText,
      surface: surfaceColor,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: dividerColor,
      outlineVariant: dividerColor,
      surfaceContainerLowest: backgroundColor,
      surfaceContainerLow: Color.lerp(backgroundColor, surfaceColor, 0.5)!,
      surfaceContainer: surfaceColor,
      surfaceContainerHigh: Color.lerp(surfaceColor, textPrimary, 0.06)!,
      surfaceContainerHighest: Color.lerp(surfaceColor, textPrimary, 0.12)!,
      surfaceTint: Colors.transparent,
    );
    const textTheme = TextTheme(
      displayLarge: TextStyle(fontSize: 12),
      displayMedium: TextStyle(fontSize: 12),
      displaySmall: TextStyle(fontSize: 12),
      headlineLarge: TextStyle(fontSize: 12),
      headlineMedium: TextStyle(fontSize: 12),
      headlineSmall: TextStyle(fontSize: 12),
      titleLarge: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(fontSize: 12),
      bodyLarge: TextStyle(fontSize: 12),
      bodyMedium: TextStyle(fontSize: 12),
      bodySmall: TextStyle(fontSize: 12),
      labelLarge: TextStyle(fontSize: 12),
      labelMedium: TextStyle(fontSize: 12),
      labelSmall: TextStyle(fontSize: 12),
    );
    final ios = platform == TargetPlatform.iOS;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      platform: platform,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: backgroundColor,
      canvasColor: backgroundColor,
      splashFactory: (ios || platform == TargetPlatform.android)
          ? NoSplash.splashFactory
          : null,
      cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
        brightness: brightness,
        primaryColor: primaryColor,
        scaffoldBackgroundColor: backgroundColor,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: backgroundColor,
        foregroundColor: textPrimary,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: ios,
        titleTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: textPrimary,
        ),
      ),
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) =>
            const GlassBackIcon(icon: Icons.chevron_left_rounded),
        closeButtonIconBuilder: (_) =>
            const GlassBackIcon(icon: Icons.close_rounded),
      ),
      iconTheme: IconThemeData(color: textPrimary),
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 0.5,
        space: 0.5,
      ),
      drawerTheme: DrawerThemeData(backgroundColor: surfaceColor),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: backgroundColor,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: primaryColor),
        unselectedIconTheme: IconThemeData(color: textSecondary),
        selectedLabelTextStyle: TextStyle(
          color: primaryColor,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: textSecondary),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        color: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ios ? 18 : 14),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ios ? 30 : 24),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceColor,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceColor,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFF1C1C1E),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
        actionTextColor: primaryColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        elevation: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primaryColor,
        linearTrackColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: unselectedBg,
        selectedColor: selectedBg,
        disabledColor: surfaceColor,
        showCheckmark: false,
        side: BorderSide.none,
        shape: ios
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: WidgetStateColor.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? selectedText
                : textPrimary,
          ),
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: selectedText,
        ),
        iconTheme: IconThemeData(color: textSecondary, size: 16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: unselectedBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        hintStyle: TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          minimumSize: const Size(64, 50),
          backgroundColor: primaryColor,
          foregroundColor: selectedText,
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: dividerColor),
          minimumSize: const Size(64, 44),
          foregroundColor: textPrimary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          foregroundColor: primaryColor,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: TextStyle(
          fontSize: 12,
          letterSpacing: 0,
          color: textPrimary,
        ),
        subtitleTextStyle: TextStyle(fontSize: 12, color: textSecondary),
      ),
      extensions: [this],
    );
  }

  @override
  AppThemeConfig copyWith({
    AppThemeMode? mode,
    String? themeName,
    Color? primaryColor,
    Color? secondaryColor,
    Color? backgroundColor,
    Color? surfaceColor,
    Color? textPrimary,
    Color? textSecondary,
    Color? dividerColor,
    Color? selectedBg,
    Color? selectedText,
    Color? unselectedBg,
    Color? unselectedText,
    Gradient? backgroundGradient,
    Gradient? selectedGradient,
    CategoryNavStyle? navStyle,
    Color? accentColor,
    Color? cardBorderColor,
    Color? glowColor,
    double? glowBlur,
    List<Shadow>? titleShadows,
    List<Shadow>? subtitleShadows,
  }) {
    return AppThemeConfig(
      mode: mode ?? this.mode,
      themeName: themeName ?? this.themeName,
      primaryColor: primaryColor ?? this.primaryColor,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      surfaceColor: surfaceColor ?? this.surfaceColor,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      dividerColor: dividerColor ?? this.dividerColor,
      selectedBg: selectedBg ?? this.selectedBg,
      selectedText: selectedText ?? this.selectedText,
      unselectedBg: unselectedBg ?? this.unselectedBg,
      unselectedText: unselectedText ?? this.unselectedText,
      backgroundGradient: backgroundGradient ?? this.backgroundGradient,
      selectedGradient: selectedGradient ?? this.selectedGradient,
      navStyle: navStyle ?? this.navStyle,
      accentColor: accentColor ?? this.accentColor,
      cardBorderColor: cardBorderColor ?? this.cardBorderColor,
      glowColor: glowColor ?? this.glowColor,
      glowBlur: glowBlur ?? this.glowBlur,
      titleShadows: titleShadows ?? this.titleShadows,
      subtitleShadows: subtitleShadows ?? this.subtitleShadows,
    );
  }

  @override
  AppThemeConfig lerp(ThemeExtension<AppThemeConfig>? other, double t) {
    if (other is! AppThemeConfig) return this;
    return AppThemeConfig(
      mode: t < 0.5 ? mode : other.mode,
      themeName: t < 0.5 ? themeName : other.themeName,
      primaryColor: Color.lerp(primaryColor, other.primaryColor, t)!,
      secondaryColor: Color.lerp(secondaryColor, other.secondaryColor, t)!,
      backgroundColor: Color.lerp(backgroundColor, other.backgroundColor, t)!,
      surfaceColor: Color.lerp(surfaceColor, other.surfaceColor, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t)!,
      selectedBg: Color.lerp(selectedBg, other.selectedBg, t)!,
      selectedText: Color.lerp(selectedText, other.selectedText, t)!,
      unselectedBg: Color.lerp(unselectedBg, other.unselectedBg, t)!,
      unselectedText: Color.lerp(unselectedText, other.unselectedText, t)!,
      backgroundGradient: Gradient.lerp(
        backgroundGradient,
        other.backgroundGradient,
        t,
      ),
      selectedGradient: Gradient.lerp(
        selectedGradient,
        other.selectedGradient,
        t,
      ),
      navStyle: t < 0.5 ? navStyle : other.navStyle,
      accentColor: Color.lerp(accentColor, other.accentColor, t)!,
      cardBorderColor: Color.lerp(cardBorderColor, other.cardBorderColor, t)!,
      glowColor: Color.lerp(glowColor, other.glowColor, t)!,
      glowBlur: glowBlur + (other.glowBlur - glowBlur) * t,
      // 阴影列表与 mode/themeName 同口径：中点切换，不逐项插值。
      titleShadows: t < 0.5 ? titleShadows : other.titleShadows,
      subtitleShadows: t < 0.5 ? subtitleShadows : other.subtitleShadows,
    );
  }
}

/// 应用级背景：有背景渐变的主题铺渐变，否则铺主题底色。
/// 位置与旧 ThemeBackgroundWrapper 相同（MaterialApp builder 最外层）。
class AppThemeBackground extends StatelessWidget {
  const AppThemeBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final gradient = config.backgroundGradient;
    if (gradient != null) {
      return DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: child,
      );
    }
    return ColoredBox(color: config.backgroundColor, child: child);
  }
}

/// 旧主题系统的自定义背景图文件清理（迁移用一次）：删应用目录
/// theme_background/ 下的旧文件。失败静默，不影响启动。
Future<void> deleteLegacyThemeBackgroundFile(String fileName) async {
  if (fileName.isEmpty) return;
  try {
    final docs = await getApplicationDocumentsDirectory();
    final file = File('${docs.path}/theme_background/$fileName');
    if (file.existsSync()) await file.delete();
  } catch (_) {}
}
