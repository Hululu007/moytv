import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'local_store.dart';

/// 外观主题：8 套固定主题，点选即时生效（不重启）。
class ThemeSettingsScreen extends StatefulWidget {
  const ThemeSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemeSettingsScreenState extends State<ThemeSettingsScreen> {
  Future<void> _select(AppThemeMode mode) async {
    await widget.store.setAppTheme(mode);
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    await widget.store.setAppTheme(AppThemeMode.purpleNeon);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final colors = Theme.of(context).colorScheme;
    final modes = AppThemeMode.values;
    return Scaffold(
      appBar: AppBar(title: const Text('外观主题')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            '8 套主题，点选即时生效；分类侧边栏样式随主题自动切换。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.35,
            ),
            itemCount: modes.length,
            itemBuilder: (context, index) {
              final mode = modes[index];
              final config = AppThemeConfig.forTheme(mode);
              return _themeCard(
                config: config,
                selected: store.appTheme == mode,
                onTap: () => _select(mode),
              );
            },
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: _reset,
            child: const Text('恢复默认主题'),
          ),
        ],
      ),
    );
  }

  Widget _themeCard({
    required AppThemeConfig config,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('app-theme-${config.mode.storageValue}'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              color: config.backgroundColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? config.primaryColor : config.dividerColor,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  config.themeName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: config.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _navStyleLabel(config.navStyle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: config.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          gradient: config.selectedGradient,
                          color: config.selectedGradient == null
                              ? config.selectedBg
                              : null,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: config.surfaceColor,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: config.dividerColor),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: config.primaryColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: config.secondaryColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
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

  String _navStyleLabel(CategoryNavStyle style) => switch (style) {
    CategoryNavStyle.darkSidebar => '简约暗黑侧边栏',
    CategoryNavStyle.colorBlockSidebar => '彩色块侧边栏',
    CategoryNavStyle.miniIconSidebar => '窄版迷你侧边栏',
    CategoryNavStyle.foldFilterSidebar => '二级筛选折叠侧边栏',
    CategoryNavStyle.lightSidebar => '浅色侧边栏',
    CategoryNavStyle.goldSidebar => '黑金侧边栏',
    CategoryNavStyle.cyberSidebar => '赛博侧边栏',
    CategoryNavStyle.tvWideSidebar => 'TV 宽侧边栏',
  };
}
