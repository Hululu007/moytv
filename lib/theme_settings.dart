import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';

class ThemeOption {
  const ThemeOption(this.id, this.name);

  final String id;
  final String name;
}

const themeModeStyleOptions = [
  ThemeOption('pureLight', '极白'),
  ThemeOption('pureDark', '极黑'),
];

const themeStyleOptions = [
  ThemeOption('neon', '霓虹暗夜'),
  ThemeOption('deep', '深邃'),
  ThemeOption('candy', '糖果活力'),
  ThemeOption('paper', '纸感复古'),
  ThemeOption('glass', '磨砂玻璃'),
  ThemeOption('aurora', '极光渐变'),
];

class ThemeAccentOption {
  const ThemeAccentOption(this.id, this.name, this.color);

  final String id;
  final String name;
  final Color color;
}

const themeAccentOptions = [
  ThemeAccentOption('jiucai', '韭菜绿', Color(0xFF4CAF50)),
  ThemeAccentOption('matcha', '抹茶绿', Color(0xFF8BC34A)),
  ThemeAccentOption('luhui', '芦荟绿', Color(0xFF66BB6A)),
  ThemeAccentOption('qingci', '青瓷', Color(0xFF4DB6AC)),
  ThemeAccentOption('boheqing', '薄荷青', Color(0xFF26C6DA)),
  ThemeAccentOption('chunrilv', '春日绿', Color(0xFF43A047)),
  ThemeAccentOption('qingkonglan', '晴空蓝', Color(0xFF42A5F5)),
  ThemeAccentOption('shenhailan', '深海蓝', Color(0xFF1E88E5)),
  ThemeAccentOption('shilan', '石蓝', Color(0xFF5C6BC0)),
  ThemeAccentOption('qunqing', '群青', Color(0xFF3949AB)),
  ThemeAccentOption('yuanwei', '鸢尾', Color(0xFF7E57C2)),
  ThemeAccentOption('xunyicao', '薰衣草', Color(0xFFBA68C8)),
  ThemeAccentOption('meizizi', '梅子紫', Color(0xFFAB47BC)),
  ThemeAccentOption('putaozi', '葡萄紫', Color(0xFF8E24AA)),
  ThemeAccentOption('xiangyuzi', '香芋紫', Color(0xFFB39DDB)),
  ThemeAccentOption('shanhuhong', '珊瑚红', Color(0xFFFF7043)),
  ThemeAccentOption('meiguifen', '玫瑰粉', Color(0xFFEC407A)),
  ThemeAccentOption('zhuanhong', '砖红', Color(0xFFE53935)),
];

const themeBackgroundOptions = [
  ThemeOption('theme', '跟随主题'),
  ThemeOption('solid', '纯色'),
  ThemeOption('gradient', '渐变'),
  ThemeOption('custom', '自定义图片'),
];

const themeBackgroundFileName = 'theme_background_image';

Color? themeAccentColor(String id) {
  if (id.startsWith('custom:')) {
    final hex = id.substring('custom:'.length);
    final value = int.tryParse(hex, radix: 16);
    if (hex.length == 6 && value != null) {
      return Color(0xFF000000 | value);
    }
    return null;
  }
  for (final option in themeAccentOptions) {
    if (option.id == id) return option.color;
  }
  return switch (id) {
    'default' => const Color(0xFFFF664F),
    'green' => const Color(0xFF2E7D32),
    'blue' => const Color(0xFF1565C0),
    'purple' => const Color(0xFF6A1B9A),
    'red' => const Color(0xFFC62828),
    'orange' => const Color(0xFFEF6C00),
    _ => null,
  };
}

ThemeMode themeModeFor(String modeStyle, String legacyMode) {
  if (modeStyle == 'pureLight') return ThemeMode.light;
  if (modeStyle == 'pureDark') return ThemeMode.dark;
  return switch (legacyMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

ThemeData applyThemePreferences(
  ThemeData base, {
  String modeStyle = '',
  String style = '',
  String accent = '',
}) {
  var scheme = base.colorScheme;
  var scaffold = base.scaffoldBackgroundColor;
  var canvas = base.canvasColor;
  var brightness = base.brightness;
  if (modeStyle == 'pureLight') {
    brightness = Brightness.light;
    scheme = scheme.copyWith(brightness: Brightness.light);
  } else if (modeStyle == 'pureDark') {
    brightness = Brightness.dark;
    scheme = scheme.copyWith(brightness: Brightness.dark);
  }
  final dark = brightness == Brightness.dark;
  if (modeStyle == 'pureLight') {
    scaffold = Colors.white;
    canvas = Colors.white;
    scheme = scheme.copyWith(
      surface: Colors.white,
      onSurface: const Color(0xFF1A1A1A),
      onSurfaceVariant: const Color(0xFF5A5A5A),
      outline: const Color(0xFFBDBDBD),
      outlineVariant: const Color(0xFFE0E0E0),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF7F7F7),
      surfaceContainer: const Color(0xFFF2F2F2),
      surfaceContainerHigh: const Color(0xFFEDEDED),
      surfaceContainerHighest: const Color(0xFFE6E6E6),
    );
  } else if (modeStyle == 'pureDark') {
    scaffold = Colors.black;
    canvas = Colors.black;
    scheme = scheme.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      onSurfaceVariant: const Color(0xFFB0B0B0),
      outline: const Color(0xFF444444),
      outlineVariant: const Color(0xFF262626),
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF121212),
      surfaceContainerHigh: const Color(0xFF1A1A1A),
      surfaceContainerHighest: const Color(0xFF242424),
    );
  }
  final accentColor = themeAccentColor(accent);
  if (accentColor != null && accent != 'default') {
    scheme = scheme.copyWith(
      primary: accentColor,
      onPrimary: Colors.white,
      primaryContainer: dark
          ? Color.lerp(accentColor, Colors.black, 0.72)!
          : Color.lerp(accentColor, Colors.white, 0.82)!,
      onPrimaryContainer: dark
          ? Color.lerp(accentColor, Colors.white, 0.82)!
          : Color.lerp(accentColor, Colors.black, 0.35)!,
    );
    scaffold = dark
        ? Color.lerp(accentColor, Colors.black, 0.88)!
        : Color.lerp(accentColor, Colors.white, 0.92)!;
    canvas = scaffold;
  }
  var cardTheme = base.cardTheme;
  var dialogTheme = base.dialogTheme;
  var bottomSheetTheme = base.bottomSheetTheme;
  var inputTheme = base.inputDecorationTheme;
  var textTheme = base.textTheme;
  var filledButtonTheme = base.filledButtonTheme;
  var elevatedButtonTheme = base.elevatedButtonTheme;
  var outlinedButtonTheme = base.outlinedButtonTheme;
  double? radius;
  if (style == 'deep' || style == 'candy' || style == 'aurora') {
    radius = 20;
  } else if (style == 'neon') {
    radius = 10;
  } else if (style == 'paper') {
    radius = 8;
  } else if (style == 'glass') {
    radius = 16;
  }
  if (radius != null) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    cardTheme = cardTheme.copyWith(shape: shape);
    dialogTheme = dialogTheme.copyWith(shape: shape);
    bottomSheetTheme = bottomSheetTheme.copyWith(shape: shape);
    inputTheme = inputTheme.copyWith(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide.none,
      ),
    );
  }
  if (style == 'candy') {
    const shape = StadiumBorder();
    filledButtonTheme = FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape),
    );
    elevatedButtonTheme = ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: shape),
    );
    outlinedButtonTheme = OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: shape),
    );
  }
  if (style == 'paper') {
    textTheme = textTheme.copyWith(
      titleLarge: textTheme.titleLarge?.copyWith(fontFamily: 'serif'),
      titleMedium: textTheme.titleMedium?.copyWith(fontFamily: 'serif'),
      titleSmall: textTheme.titleSmall?.copyWith(fontFamily: 'serif'),
    );
  }
  if (style == 'glass') {
    scheme = scheme.copyWith(
      surface: scheme.surface.withValues(alpha: 0.85),
      surfaceContainerLowest: scheme.surfaceContainerLowest.withValues(
        alpha: 0.85,
      ),
      surfaceContainerLow: scheme.surfaceContainerLow.withValues(alpha: 0.85),
      surfaceContainer: scheme.surfaceContainer.withValues(alpha: 0.85),
      surfaceContainerHigh: scheme.surfaceContainerHigh.withValues(
        alpha: 0.85,
      ),
      surfaceContainerHighest: scheme.surfaceContainerHighest.withValues(
        alpha: 0.85,
      ),
      outline: dark ? Colors.white38 : Colors.black26,
    );
  }
  if (style == 'neon') {
    scheme = scheme.copyWith(
      outline: scheme.primary,
      outlineVariant: scheme.primary.withValues(alpha: 0.35),
    );
    cardTheme = cardTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius ?? 10),
        side: BorderSide(
          color: scheme.primary.withValues(alpha: 0.55),
          width: 1,
        ),
      ),
    );
  }
  if (style == 'aurora') {
    scheme = scheme.copyWith(surfaceTint: scheme.primary);
  }
  if (style == 'deep') {
    cardTheme = cardTheme.copyWith(elevation: 2);
    scheme = scheme.copyWith(
      surfaceTint: const Color(0xFF3B6EA5),
      surfaceContainerLowest: dark
          ? const Color(0xFF0B1220)
          : const Color(0xFFE8EEF5),
      surfaceContainerLow: dark
          ? const Color(0xFF101A2E)
          : const Color(0xFFDCE6F2),
      surfaceContainer: dark
          ? const Color(0xFF16223A)
          : const Color(0xFFCFDDF0),
    );
  }
  if (style == 'paper' && !dark) {
    scaffold = const Color(0xFFFBF6EC);
    canvas = const Color(0xFFFBF6EC);
    scheme = scheme.copyWith(
      surface: const Color(0xFFFDFAF2),
      surfaceContainerLowest: const Color(0xFFFDFAF2),
      surfaceContainerLow: const Color(0xFFF8F1DE),
      surfaceContainer: const Color(0xFFF3EAD3),
      surfaceContainerHigh: const Color(0xFFEDE2C8),
      surfaceContainerHighest: const Color(0xFFE5D8BC),
      outline: const Color(0xFFC9BFA5),
      outlineVariant: const Color(0xFFE0D6BE),
    );
  }
  return base.copyWith(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffold,
    canvasColor: canvas,
    appBarTheme: base.appBarTheme.copyWith(backgroundColor: scaffold),
    drawerTheme: DrawerThemeData(backgroundColor: scheme.surface),
    cardTheme: cardTheme,
    dialogTheme: dialogTheme,
    bottomSheetTheme: bottomSheetTheme,
    inputDecorationTheme: inputTheme,
    textTheme: textTheme,
    filledButtonTheme: filledButtonTheme,
    elevatedButtonTheme: elevatedButtonTheme,
    outlinedButtonTheme: outlinedButtonTheme,
  );
}

Future<Directory> _themeBackgroundDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/theme_background');
}

Future<File?> themeBackgroundFile(String fileName) async {
  if (fileName.isEmpty) return null;
  final dir = await _themeBackgroundDir();
  final file = File('${dir.path}/$fileName');
  return file.existsSync() ? file : null;
}

Future<String> saveThemeBackgroundImage(
  List<int> bytes,
  String extension,
) async {
  final dir = await _themeBackgroundDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final safeExt = extension.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final fileName = safeExt.isEmpty
      ? themeBackgroundFileName
      : '$themeBackgroundFileName.$safeExt';
  await File('${dir.path}/$fileName').writeAsBytes(bytes, flush: true);
  return fileName;
}

Future<void> deleteThemeBackgroundImage(String fileName) async {
  if (fileName.isEmpty) return;
  try {
    final dir = await _themeBackgroundDir();
    final file = File('${dir.path}/$fileName');
    if (file.existsSync()) await file.delete();
  } catch (_) {}
}

class ThemeBackgroundWrapper extends StatefulWidget {
  const ThemeBackgroundWrapper({
    super.key,
    required this.store,
    required this.child,
  });

  final LocalStore? store;
  final Widget child;

  @override
  State<ThemeBackgroundWrapper> createState() => _ThemeBackgroundWrapperState();
}

class _ThemeBackgroundWrapperState extends State<ThemeBackgroundWrapper> {
  File? _image;
  String _resolvedFor = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ThemeBackgroundWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  Future<void> _resolve() async {
    final store = widget.store;
    if (store == null) return;
    final fileName = store.themeBackgroundImage;
    if (store.themeBackground != 'custom' || fileName.isEmpty) {
      if (_image != null && mounted) setState(() => _image = null);
      _resolvedFor = '';
      return;
    }
    if (fileName == _resolvedFor) return;
    final file = await themeBackgroundFile(fileName);
    if (!mounted) return;
    setState(() {
      _image = file;
      _resolvedFor = fileName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = widget.store;
    final background = store?.themeBackground ?? 'theme';
    final scaffold = theme.scaffoldBackgroundColor;
    if (background == 'solid') {
      return ColoredBox(
        color: theme.colorScheme.primaryContainer,
        child: widget.child,
      );
    }
    if (background == 'gradient') {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [theme.colorScheme.primaryContainer, scaffold],
          ),
        ),
        child: widget.child,
      );
    }
    if (background == 'custom' && _image != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(_image!, fit: BoxFit.cover),
          widget.child,
        ],
      );
    }
    return ColoredBox(color: scaffold, child: widget.child);
  }
}
