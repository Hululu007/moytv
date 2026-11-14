import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'liquid_glass.dart';

/// 全局主题：8 套固定主题（用户 2026-11-13 发来的代码定版）。
///
/// 配色与名字与用户文件逐字一致；每套主题绑定一种分类侧边栏样式。
/// 亮暗由各主题自身底色决定，不再跟随系统、不再套旧的 light/dark 两套。
enum AppThemeMode {
  purpleNeon,
  lightClean,
  goldVip,
  cyberBlue,
  kidFamily,
  minimalCard,
  retroFilm,
  tvBigScreen;

  String get storageValue => name;

  static AppThemeMode fromStorageValue(String? value) =>
      AppThemeMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => AppThemeMode.purpleNeon,
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

  static NavStyle fromStorageValue(String? value) => NavStyle.values
      .firstWhere(
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

  static ContentTier fromStorageValue(String? value) =>
      ContentTier.values.firstWhere(
        (tier) => tier.name == value,
        orElse: () => ContentTier.all,
      );
}

/// 主题绑定的显示方案：导航样式 + 内容档。切主题时两件一起变。
///
/// 存储值格式为 `导航样式:内容档`（如 `bottomTabs:manhua`）；只写导航
/// 样式的旧值（如 `drawer`）解析时内容档回落全部内容；非法值整体回默认。
class ThemeDisplayScheme {
  const ThemeDisplayScheme({
    this.navStyle = NavStyle.drawer,
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
    return ThemeDisplayScheme(
      navStyle: NavStyle.fromStorageValue(parts.first),
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

enum CategoryNavStyle {
  darkSidebar,
  colorBlockSidebar,
  miniIconSidebar,
  foldFilterSidebar,
  lightSidebar,
  goldSidebar,
  cyberSidebar,
  tvWideSidebar,
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

  /// 亮暗由底色定：浅色清爽 / 亲子儿童 / 极简卡片是浅底，其余是深底。
  Brightness get brightness => switch (mode) {
    AppThemeMode.lightClean ||
    AppThemeMode.kidFamily ||
    AppThemeMode.minimalCard => Brightness.light,
    _ => Brightness.dark,
  };

  bool get isDark => brightness == Brightness.dark;

  static AppThemeConfig of(BuildContext context) =>
      Theme.of(context).extension<AppThemeConfig>() ??
      AppThemeConfig.forTheme(AppThemeMode.purpleNeon);

  factory AppThemeConfig.forTheme(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.purpleNeon:
        return AppThemeConfig(
          mode: mode,
          themeName: '紫蓝霓虹',
          primaryColor: Color(0xFFE847A2),
          secondaryColor: Color(0xFF7B42E0),
          backgroundColor: Color(0xFF14102A),
          surfaceColor: Color(0xFF1F1A3C),
          textPrimary: Colors.white,
          textSecondary: Colors.white70,
          dividerColor: Colors.white12,
          selectedBg: Color(0xFFE847A2),
          selectedText: Colors.white,
          unselectedBg: Colors.white12,
          unselectedText: Colors.white70,
          backgroundGradient: LinearGradient(
            colors: [Color(0xFF5B2C99), Color(0xFF2478C2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          selectedGradient: LinearGradient(
            colors: [Color(0xFFE847A2), Color(0xFF7B42E0)],
          ),
          navStyle: CategoryNavStyle.darkSidebar,
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
      splashFactory:
          (ios || platform == TargetPlatform.android)
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
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
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
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
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
