import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';

/// 外观主题：8 套固定主题，点选即时生效（不重启）。
///
/// 每张主题卡片带一块真实内容小预览：当前站源拉回的分类名与视频卡
/// （标题 + 封面），用该主题自身的配色画。没有仓库或拉不到数据时只显示
/// 配色条，不造假数据。
class ThemeSettingsScreen extends StatefulWidget {
  const ThemeSettingsScreen({
    super.key,
    required this.store,
    this.repository,
    this.sourceId,
  });

  final LocalStore store;

  /// 取真实内容用的仓库；为空时卡片只显示配色。
  final AppRepository? repository;

  /// 取真实内容用的站源 id；为空时卡片只显示配色。
  final String? sourceId;

  @override
  State<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemePreviewData {
  const _ThemePreviewData({required this.categories, required this.items});
  final List<CatalogCategory> categories;
  final List<Drama> items;
}

class _ThemeSettingsScreenState extends State<ThemeSettingsScreen> {
  Future<_ThemePreviewData?>? _previewFuture;

  bool get _showsPreview =>
      widget.repository != null && (widget.sourceId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_showsPreview) _previewFuture = _loadPreview();
  }

  Future<_ThemePreviewData?> _loadPreview() async {
    final repository = widget.repository!;
    final source = widget.sourceId!;
    final results = await Future.wait([
      repository.categories(source),
      repository.catalog(source, page: 1),
    ]);
    final categories = (results[0] as List<CatalogCategory>)
        .where((category) => category.name.isNotEmpty && category.name != '全部')
        .take(3)
        .toList();
    final items = (results[1] as CatalogPage)
        .items
        .where((drama) => drama.title.isNotEmpty)
        .take(3)
        .toList();
    if (categories.isEmpty && items.isEmpty) return null;
    return _ThemePreviewData(categories: categories, items: items);
  }

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
          FutureBuilder<_ThemePreviewData?>(
            future: _previewFuture,
            builder: (context, snapshot) {
              final preview = snapshot.data;
              final failed = snapshot.hasError;
              final loading =
                  _showsPreview &&
                  snapshot.connectionState == ConnectionState.waiting;
              // 两列卡片不用 GridView 定高：卡片内容高度由真实数据决定
              // （分类胶囊可能换行），行高随内容走才不会溢出。
              final cards = [
                for (final mode in modes)
                  _themeCard(
                    config: AppThemeConfig.forTheme(mode),
                    selected: store.appTheme == mode,
                    preview: preview,
                    previewLoading: loading,
                    previewFailed: failed,
                    onTap: () => _select(mode),
                  ),
              ];
              final rows = <Widget>[];
              for (var i = 0; i < cards.length; i += 2) {
                rows.add(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: cards[i]),
                      const SizedBox(width: 10),
                      if (i + 1 < cards.length)
                        Expanded(child: cards[i + 1])
                      else
                        const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
                );
                if (i + 2 < cards.length) {
                  rows.add(const SizedBox(height: 10));
                }
              }
              return Column(children: rows);
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
    required _ThemePreviewData? preview,
    required bool previewLoading,
    required bool previewFailed,
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
                if (_showsPreview) ...[
                  const SizedBox(height: 8),
                  _previewZone(config, preview, previewLoading, previewFailed),
                ],
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
                const SizedBox(height: 8),
                _tierRow(config),
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

  /// 每张卡的“显示内容”选择行：显示该主题绑定的内容档，点按打开
  /// 四档选择弹窗。内层 InkWell 优先于卡片外层点选，点这里只改档、
  /// 不切主题（点卡片其它区域才切主题）。
  Widget _tierRow(AppThemeConfig config) {
    final tier = widget.store
        .displayScheme(config.mode)
        .contentTier;
    return InkWell(
      key: ValueKey('theme-tier-${config.mode.storageValue}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _chooseTier(config.mode),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: config.unselectedBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: config.dividerColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '显示内容：${tier.label}',
                style: TextStyle(fontSize: 12, color: config.textSecondary),
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 16,
              color: config.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseTier(AppThemeMode mode) async {
    final scheme = widget.store.displayScheme(mode);
    final selected = await showDialog<ContentTier>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${AppThemeConfig.forTheme(mode).themeName} · 显示内容'),
        children: [
          RadioGroup<ContentTier>(
            groupValue: scheme.contentTier,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              children: [
                for (final tier in ContentTier.values)
                  RadioListTile<ContentTier>(
                    value: tier,
                    title: Text(tier.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == scheme.contentTier) return;
    await saveUserChange(
      context,
      () => widget.store.setDisplayScheme(
        mode,
        scheme.copyWith(contentTier: selected),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 卡片内的真实内容小预览：视频卡（封面 + 标题）与分类名胶囊，
  /// 全部用该卡片主题自身的配色画。
  Widget _previewZone(
    AppThemeConfig config,
    _ThemePreviewData? preview,
    bool loading,
    bool failed,
  ) {
    if (loading) {
      return SizedBox(
        height: 104,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: config.textSecondary,
            ),
          ),
        ),
      );
    }
    if (failed || preview == null) {
      return SizedBox(
        height: 104,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            failed ? '内容未加载' : '暂无内容',
            style: TextStyle(fontSize: 11, color: config.textSecondary),
          ),
        ),
      );
    }
    final repository = widget.repository!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preview.items.isNotEmpty)
          Row(
            children: [
              for (var i = 0; i < preview.items.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: i == preview.items.length - 1 ? 0 : 6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            height: 52,
                            width: double.infinity,
                            child: DramaCover(
                              drama: preview.items[i],
                              repository: repository,
                              radius: 6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        SizedBox(
                          height: 24,
                          child: Text(
                            preview.items[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              fontSize: 9,
                              height: 1.3,
                              color: config.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        if (preview.categories.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final category in preview.categories)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: config.unselectedBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: config.dividerColor),
                  ),
                  child: Text(
                    category.name,
                    style: TextStyle(
                      fontSize: 9,
                      color: config.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
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
