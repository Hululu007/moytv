import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'local_store.dart';
import 'theme_settings.dart';

class ThemeSettingsScreen extends StatefulWidget {
  const ThemeSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemeSettingsScreenState extends State<ThemeSettingsScreen> {
  bool _picking = false;

  Future<void> _pickImage() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      final file = files.isEmpty ? null : files.first;
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final name = file.name;
      final dot = name.lastIndexOf('.');
      final ext = dot >= 0 ? name.substring(dot + 1) : '';
      final saved = await saveThemeBackgroundImage(bytes, ext);
      await widget.store.setThemeBackgroundImage(saved);
      await widget.store.setThemeBackground('custom');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _clearImage() async {
    final fileName = widget.store.themeBackgroundImage;
    await deleteThemeBackgroundImage(fileName);
    await widget.store.setThemeBackgroundImage('');
    await widget.store.setThemeBackground('theme');
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    final fileName = widget.store.themeBackgroundImage;
    await deleteThemeBackgroundImage(fileName);
    await widget.store.resetThemeSettings();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('主题风格')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            '主题模式管亮暗与表面，界面风格管形状与材质，主题色管点缀色；三者自由组合，点选即时生效。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
          ),
          _sectionTitle('主题模式'),
          Row(
            children: [
              for (final option in themeModeStyleOptions)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: option.id == 'pureLight' ? 0 : 6,
                      right: option.id == 'pureLight' ? 6 : 0,
                    ),
                    child: _selectCard(
                      title: option.id == 'pureLight' ? '极白模式' : '极黑模式',
                      subtitle: option.id == 'pureLight'
                          ? '纯白画布，最高对比'
                          : '纯黑画布，OLED 省电',
                      selected: store.themeModeStyle == option.id,
                      onTap: () async {
                        await store.setThemeModeStyle(option.id);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
            ],
          ),
          _sectionTitle('亮暗'),
          Row(
            children: [
              for (final mode in ['system', 'light', 'dark'])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: mode == 'system' ? 0 : 6,
                      right: mode == 'dark' ? 0 : 6,
                    ),
                    child: _selectCard(
                      title: mode == 'system'
                          ? '跟随系统'
                          : mode == 'light'
                              ? '浅色'
                              : '深色',
                      subtitle: mode == 'system'
                          ? '跟随手机系统'
                          : mode == 'light'
                              ? '浅色界面'
                              : '深色界面',
                      selected: store.themeModeStyle.isEmpty &&
                          store.themeMode == mode,
                      onTap: () async {
                        await store.setThemeMode(mode);
                        await store.setThemeModeStyle('');
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
            ],
          ),
          _sectionTitle('界面风格'),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.55,
            ),
            itemCount: themeStyleOptions.length,
            itemBuilder: (context, index) {
              final option = themeStyleOptions[index];
              return _selectCard(
                title: option.name,
                subtitle: _styleSubtitle(option.id),
                preview: _stylePreview(option.id),
                selected: store.themeStyle == option.id,
                onTap: () async {
                  await store.setThemeStyle(option.id);
                  if (mounted) setState(() {});
                },
              );
            },
          ),
          _sectionTitle('主题色'),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 12,
              crossAxisSpacing: 8,
              childAspectRatio: 0.78,
            ),
            itemCount: themeAccentOptions.length + 1,
            itemBuilder: (context, index) {
              if (index == themeAccentOptions.length) {
                return _customAccentTile();
              }
              final option = themeAccentOptions[index];
              final selected = store.themeAccent == option.id;
              return InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () async {
                  await store.setThemeAccent(option.id);
                  if (mounted) setState(() {});
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: option.color,
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(
                                color: colors.primary,
                                width: 2,
                              )
                            : null,
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      option.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w700
                            : null,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          _sectionTitle('背景'),
          for (final option in themeBackgroundOptions)
            _optionRow(
              title: option.name,
              subtitle: _backgroundSubtitle(option.id),
              selected: store.themeBackground == option.id,
              onTap: () async {
                await store.setThemeBackground(option.id);
                if (mounted) setState(() {});
              },
            ),
          if (store.themeBackground == 'custom') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _picking ? null : _pickImage,
                    icon: const Icon(Icons.image_rounded),
                    label: Text(
                      store.themeBackgroundImage.isEmpty
                          ? '选择背景图片'
                          : '更换背景图片',
                    ),
                  ),
                ),
                if (store.themeBackgroundImage.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _clearImage,
                    child: const Text('清除图片'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '图片会复制到应用目录保存，不依赖原图路径。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: _reset,
            child: const Text('恢复默认主题'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(
      children: [
        Container(width: 3, height: 16, color: Colors.blue),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _selectCard({
    required String title,
    required String subtitle,
    List<Color>? preview,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              color: selected
                  ? colors.primaryContainer.withValues(alpha: 0.35)
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(color: colors.primary, width: 1.5)
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: selected ? colors.primary : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (preview != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (var i = 0; i < preview.length; i++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: i == 0 ? 0 : 3,
                              right: i == preview.length - 1 ? 0 : 3,
                            ),
                            child: Container(
                              height: 10,
                              decoration: BoxDecoration(
                                color: preview[i],
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (selected)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                Icons.check_circle_rounded,
                color: colors.primary,
                size: 20,
              ),
            ),
        ],
      ),
    );
  }

  List<Color> _stylePreview(String id) {
    if (id == 'neon') {
      return const [
        Color(0xFFB8D4F0),
        Color(0xFFFF2E88),
        Color(0xFF00E5FF),
      ];
    }
    return const [
      Color(0xFFB8D4F0),
      Color(0xFF7C5CFF),
      Color(0xFF2EE5A6),
    ];
  }

  Widget _customAccentTile() {
    final colors = Theme.of(context).colorScheme;
    final accent = widget.store.themeAccent;
    final custom = accent.startsWith('custom:')
        ? themeAccentColor(accent)
        : null;
    final selected = custom != null;
    return InkWell(
      key: const ValueKey('custom-accent-tile'),
      borderRadius: BorderRadius.circular(24),
      onTap: () async {
        await _showCustomColorDialog();
        if (mounted) setState(() {});
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: custom ?? colors.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(color: colors.primary, width: 2)
                  : null,
            ),
            child: custom == null
                ? Icon(
                    Icons.add_rounded,
                    color: colors.onSurfaceVariant,
                    size: 20,
                  )
                : Icon(
                    Icons.check_rounded,
                    color:
                        ThemeData.estimateBrightnessForColor(custom) ==
                                Brightness.light
                            ? Colors.black
                            : Colors.white,
                    size: 20,
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            '自定义',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: selected ? colors.primary : colors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCustomColorDialog() async {
    final store = widget.store;
    final current =
        themeAccentColor(store.themeAccent) ?? const Color(0xFF1E88E5);
    var red = (current.r * 255.0).round().clamp(0, 255).toDouble();
    var green = (current.g * 255.0).round().clamp(0, 255).toDouble();
    var blue = (current.b * 255.0).round().clamp(0, 255).toDouble();
    final hexController = TextEditingController(
      text: _rgbHex(red.toInt(), green.toInt(), blue.toInt()),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final color = Color.fromARGB(
              255,
              red.toInt(),
              green.toInt(),
              blue.toInt(),
            );
            void syncHex() {
              hexController.text = _rgbHex(
                red.toInt(),
                green.toInt(),
                blue.toInt(),
              );
            }
            return AlertDialog(
              title: const Text('自定义主题色'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 56,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '#${_rgbHex(red.toInt(), green.toInt(), blue.toInt())}',
                      style: TextStyle(
                        color:
                            ThemeData.estimateBrightnessForColor(color) ==
                                    Brightness.light
                                ? Colors.black
                                : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _colorSlider('红', red, Colors.red, (value) {
                    setDialogState(() {
                      red = value;
                      syncHex();
                    });
                  }),
                  _colorSlider('绿', green, Colors.green, (value) {
                    setDialogState(() {
                      green = value;
                      syncHex();
                    });
                  }),
                  _colorSlider('蓝', blue, Colors.blue, (value) {
                    setDialogState(() {
                      blue = value;
                      syncHex();
                    });
                  }),
                  const SizedBox(height: 8),
                  TextField(
                    controller: hexController,
                    decoration: const InputDecoration(
                      labelText: '十六进制颜色',
                      prefixText: '#',
                    ),
                    maxLength: 6,
                    onChanged: (text) {
                      final value = int.tryParse(text, radix: 16);
                      if (text.length == 6 && value != null) {
                        setDialogState(() {
                          red = ((value >> 16) & 0xFF).toDouble();
                          green = ((value >> 8) & 0xFF).toDouble();
                          blue = (value & 0xFF).toDouble();
                        });
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed == true && mounted) {
      await store.setThemeAccent(
        'custom:${_rgbHex(red.toInt(), green.toInt(), blue.toInt())}',
      );
      if (mounted) setState(() {});
    }
  }

  String _rgbHex(int red, int green, int blue) =>
      '${red.toRadixString(16).padLeft(2, '0')}'
              '${green.toRadixString(16).padLeft(2, '0')}'
              '${blue.toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();

  Widget _colorSlider(
    String label,
    double value,
    Color color,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            activeColor: color,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 32, child: Text(value.toInt().toString())),
      ],
    );
  }

  Widget _optionRow({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) => ListTile(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: selected
        ? const Icon(Icons.check_rounded, color: Colors.green)
        : null,
    onTap: onTap,
  );

  String _styleSubtitle(String id) => switch (id) {
    'neon' => '黑底·品红/青霓虹·发光描边',
    'deep' => '蓝黑分层·大圆角·左右滑页',
    'candy' => '大圆角·高饱和·全圆按钮',
    'paper' => '纸底·衬线标题·重分隔线',
    'glass' => '半透卡面·白描边·顶部柔光',
    'aurora' => '紫青氛围光·大圆角·冷调',
    _ => '',
  };

  String _backgroundSubtitle(String id) => switch (id) {
    'theme' => '跟随当前主题',
    'solid' => '主题色纯色底',
    'gradient' => '主题色到背景渐变',
    'custom' => '从相册选一张图作背景',
    _ => '',
  };
}
