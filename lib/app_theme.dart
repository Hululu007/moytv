import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'liquid_glass.dart';

abstract final class AppTheme {
  static final light = _theme(Brightness.light);
  static final dark = _theme(Brightness.dark);
  static final iosLight = _glass(Brightness.light, TargetPlatform.iOS);
  static final iosDark = _glass(Brightness.dark, TargetPlatform.iOS);
  static final _glassThemes = <(TargetPlatform, Brightness), ThemeData>{};

  static ThemeData get platformLight => _platformTheme(Brightness.light);
  static ThemeData get platformDark => _platformTheme(Brightness.dark);

  static ThemeData _platformTheme(Brightness brightness) {
    final platform = defaultTargetPlatform;
    if (platform == TargetPlatform.iOS) {
      return brightness == Brightness.dark ? iosDark : iosLight;
    }
    // 仅 Android 使用玻璃主题；Windows 回退到标准 Material 主题，与参考项目
    // guoappxx 一致，避免 Windows 软光栅/ANGLE 渲染下整页黑屏。
    if (platform == TargetPlatform.android) {
      return _glassThemes.putIfAbsent((
        platform,
        brightness,
      ), () => _glass(brightness, platform));
    }
    return brightness == Brightness.dark ? dark : light;
  }

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xFF07040E) : const Color(0xFFF3EDFF);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB14BFF),
      brightness: brightness,
      primary: dark ? const Color(0xFFB14BFF) : const Color(0xFF7B2FD1),
      onPrimary: Colors.white,
      primaryContainer: dark
          ? const Color(0xFF2A1247)
          : const Color(0xFFEADCFF),
      onPrimaryContainer: dark
          ? const Color(0xFFE8D6FF)
          : const Color(0xFF3A0E63),
      tertiary: dark ? const Color(0xFF33E1FF) : const Color(0xFF00677A),
      surface: dark ? const Color(0xFF150C26) : Colors.white,
      onSurface: dark ? const Color(0xFFF6F1FF) : const Color(0xFF1B1128),
      onSurfaceVariant: dark
          ? const Color(0xFFB9B6C2)
          : const Color(0xFF68636C),
      outline: dark ? const Color(0xFF85818B) : const Color(0xFF7C757D),
      outlineVariant: dark ? const Color(0xFF34343D) : const Color(0xFFE3DFDC),
      surfaceContainerLowest: dark ? const Color(0xFF0D0E11) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF191A20)
          : const Color(0xFFF7F3F0),
      surfaceContainer: dark
          ? const Color(0xFF1E2026)
          : const Color(0xFFF2EEEB),
      surfaceContainerHigh: dark
          ? const Color(0xFF25262D)
          : const Color(0xFFEDE8E5),
      surfaceContainerHighest: dark
          ? const Color(0xFF30313A)
          : const Color(0xFFE6E0DC),
      surfaceTint: Colors.transparent,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 12),
        displayMedium: TextStyle(fontSize: 12),
        displaySmall: TextStyle(fontSize: 12),
        headlineLarge: TextStyle(fontSize: 12),
        headlineMedium: TextStyle(fontSize: 12),
        headlineSmall: TextStyle(fontSize: 12),
        titleLarge: TextStyle(fontSize: 12),
        titleMedium: TextStyle(fontSize: 12),
        titleSmall: TextStyle(fontSize: 12),
        bodyLarge: TextStyle(fontSize: 12),
        bodyMedium: TextStyle(fontSize: 12),
        bodySmall: TextStyle(fontSize: 12),
        labelLarge: TextStyle(fontSize: 12),
        labelMedium: TextStyle(fontSize: 12),
        labelSmall: TextStyle(fontSize: 12),
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      drawerTheme: DrawerThemeData(backgroundColor: scheme.surface),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  static ThemeData _glass(Brightness brightness, TargetPlatform platform) {
    final dark = brightness == Brightness.dark;
    final ios = platform == TargetPlatform.iOS;
    final background = dark
        ? ios
              ? const Color(0xFF07040E)
              : const Color(0xFF07040E)
        : const Color(0xFFF3EDFF);
    final primary = dark ? const Color(0xFFB14BFF) : const Color(0xFF7B2FD1);
    final label = dark ? const Color(0xFFF6F1FF) : const Color(0xFF1B1128);
    final secondary = dark ? const Color(0xFFB4A5CE) : const Color(0xFF6B5C86);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: dark
          ? const Color(0xFF2A1247)
          : const Color(0xFFEADCFF),
      onPrimaryContainer: dark
          ? const Color(0xFFE8D6FF)
          : const Color(0xFF3A0E63),
      secondaryContainer: dark
          ? const Color(0xFF241338)
          : const Color(0xFFE9E1F7),
      onSecondaryContainer: label,
      tertiary: dark ? const Color(0xFF33E1FF) : const Color(0xFF00677A),
      surface: dark ? const Color(0xFF150C26) : Colors.white,
      onSurface: label,
      onSurfaceVariant: secondary,
      outline: dark ? const Color(0xFF54406E) : const Color(0xFFCBBEDD),
      outlineVariant: dark ? const Color(0xFF2E1D45) : const Color(0xFFE5DCF2),
      surfaceContainerLowest: dark ? const Color(0xFF07040E) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF0F0820)
          : const Color(0xFFF6F1FD),
      surfaceContainer: dark
          ? const Color(0xFF150C26)
          : const Color(0xFFEFE8FA),
      surfaceContainerHigh: dark
          ? const Color(0xFF1E1033)
          : const Color(0xFFE8DDF6),
      surfaceContainerHighest: dark
          ? const Color(0xFF2A1745)
          : const Color(0xFFDFD2F0),
      surfaceTint: Colors.transparent,
    );
    const continuous = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(18)),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      platform: platform,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: label.withValues(alpha: .06),
      hoverColor: label.withValues(alpha: .04),
      cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
        brightness: brightness,
        primaryColor: primary,
        scaffoldBackgroundColor: background,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: label,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: label,
        ),
        systemOverlayStyle: systemBars(brightness),
      ),
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) =>
            const GlassBackIcon(icon: LucideIcons.chevronLeft),
        closeButtonIconBuilder: (_) => const GlassBackIcon(icon: LucideIcons.x),
      ),
      iconTheme: IconThemeData(color: label),
      drawerTheme: DrawerThemeData(backgroundColor: scheme.surface),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: .5,
        space: .5,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: dark
            ? const Color(0xFF1C1C1E)
            : const Color(0xFFEAE8E5),
        selectedColor: label,
        disabledColor: scheme.surfaceContainer,
        showCheckmark: false,
        side: BorderSide.none,
        shape: ios
            ? const StadiumBorder()
            : const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: WidgetStateColor.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? background : label,
          ),
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: background,
        ),
        iconTheme: IconThemeData(color: secondary, size: 16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1C1C1E) : const Color(0xFFEAE8E5),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        hintStyle: TextStyle(color: secondary),
        prefixIconColor: secondary,
        suffixIconColor: secondary,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          minimumSize: const Size(64, 50),
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
          side: BorderSide(color: scheme.outline),
          minimumSize: const Size(64, 44),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        color: dark ? const Color(0xFF1C1C1E) : Colors.white,
        shape: ios
            ? continuous
            : const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: secondary,
        shape: continuous,
        titleTextStyle: TextStyle(fontSize: 12, letterSpacing: 0, color: label),
        subtitleTextStyle: TextStyle(fontSize: 12, color: secondary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xFF232325) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(30)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? const Color(0xFF252527) : Colors.white,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: .3),
        shape: continuous,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(34)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFF1C1C1E),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
        actionTextColor: primary,
        shape: continuous,
        elevation: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: Colors.transparent,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: primary),
        unselectedIconTheme: IconThemeData(color: secondary),
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        displayLarge: base.textTheme.displayLarge?.copyWith(fontSize: 12),
        displayMedium: base.textTheme.displayMedium?.copyWith(fontSize: 12),
        displaySmall: base.textTheme.displaySmall?.copyWith(fontSize: 12),
        headlineLarge: base.textTheme.headlineLarge?.copyWith(fontSize: 12),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(fontSize: 12),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(fontSize: 12),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 12),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 12),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 12),
        bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 12),
        labelMedium: base.textTheme.labelMedium?.copyWith(fontSize: 12),
        labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 12),
      ),
    );
  }
}
