import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'neon_glass_kit.dart';
import 'site_icon.dart';

class SourcePickerEntry {
  const SourcePickerEntry({
    required this.id,
    required this.name,
    this.deletable = true,
    this.iconUrls = const [],
  });

  final String id;
  final String name;
  final bool deletable;

  /// 调用方给定的站标候选地址（按序尝试）。为空时按 [id] 查 jar 站
  /// ext 与 py/Go/阅读桥接表派生；都为空则宫格显示图案标，不联网。
  final List<String> iconUrls;
}

class SourcePickerGroup {
  const SourcePickerGroup({
    required this.title,
    required this.entries,
    this.zone = zoneBuiltin,
  });

  final String title;
  final List<SourcePickerEntry> entries;

  /// 双区翻页分区：builtin=内置区，import=导入区（本地导入 +
  /// 远程配置）。默认 builtin；直播/阅读弹窗不分区，不传即全进
  /// 内置区、不翻页。
  static const zoneBuiltin = 'builtin';
  static const zoneImport = 'import';

  final String zone;
}

class _EditableGroup {
  _EditableGroup(this.title, this.entries, {this.zone = ''});

  final String title;
  final List<SourcePickerEntry> entries;
  final String zone;
}

Future<String?> showSitePickerDialog(
  BuildContext context, {
  required String sectionName,
  required String currentId,
  required List<SourcePickerGroup> groups,
  bool initialEditMode = false,
  Future<bool> Function(SourcePickerEntry entry)? onDeleteSite,

  /// 非空时弹窗顶部右上角显示 + 号导入钮：点 + 先关弹窗、再调
  /// 此回调（调用方打开导入分流、导完刷新站源）。不传则无 + 号
  /// （直播/阅读区不传，只在片库区接导入）。
  Future<void> Function()? onImport,

  /// 双区开关（只在片库区传 true）：内置区 / 导入区
  /// 用淡入淡出切换；不传时保持原来的单列表。
  bool enableZoneFlip = false,

  /// 打开时默认显示的区：0 内置区，1 导入区。导入成功后调用方
  /// 重开弹窗传 1，列表自动落到导入区。
  int initialZoneIndex = 0,
}) => showDialog<String>(
  context: context,
  builder: (context) => SitePickerDialog(
    sectionName: sectionName,
    currentId: currentId,
    groups: groups,
    initialEditMode: initialEditMode,
    onDeleteSite: onDeleteSite,
    onImport: onImport,
    enableZoneFlip: enableZoneFlip,
    initialZoneIndex: initialZoneIndex,
  ),
);

class SitePickerDialog extends StatefulWidget {
  const SitePickerDialog({
    super.key,
    required this.sectionName,
    required this.currentId,
    required this.groups,
    this.initialEditMode = false,
    this.onDeleteSite,
    this.onImport,
    this.enableZoneFlip = false,
    this.initialZoneIndex = 0,
  });

  final String sectionName;
  final String currentId;
  final List<SourcePickerGroup> groups;
  final bool initialEditMode;
  final Future<bool> Function(SourcePickerEntry entry)? onDeleteSite;
  final Future<void> Function()? onImport;
  final bool enableZoneFlip;
  final int initialZoneIndex;

  @override
  State<SitePickerDialog> createState() => _SitePickerDialogState();
}

class _SitePickerDialogState extends State<SitePickerDialog> {
  final _searchController = TextEditingController();
  final _currentKey = GlobalKey();
  String _query = '';
  bool _scrolledToCurrent = false;
  int _scrollSteps = 0;
  double _lastMaxExtent = -1;
  late bool _editMode;
  late List<_EditableGroup> _groups;

  /// 双区：0 内置区，1 导入区；每区一个滚动控制器（切换过渡
  /// 期两区列表同时在树里，共用一个控制器会断言失败）。
  late int _zoneIndex;
  final _zoneScrollControllers = [ScrollController(), ScrollController()];

  /// 翻页只在片库区开：调用方传 enableZoneFlip 才翻；直播/阅读
  /// 弹窗不传，永远是原来的单列表。
  bool get _flipEnabled => widget.enableZoneFlip;

  List<_EditableGroup> _zoneGroups(int zone) => [
    for (final group in _groups)
      if ((zone == 1) == (group.zone == SourcePickerGroup.zoneImport)) group,
  ];

  int _zoneEntryCount(int zone) =>
      _zoneGroups(zone).fold(0, (sum, group) => sum + group.entries.length);

  ScrollController get _activeScrollController =>
      _zoneScrollControllers[_flipEnabled ? _zoneIndex : 0];

  @override
  void initState() {
    super.initState();
    _editMode = widget.initialEditMode && widget.onDeleteSite != null;
    _zoneIndex = widget.initialZoneIndex == 1 ? 1 : 0;
    _groups = [
      for (final group in widget.groups)
        _EditableGroup(group.title, List.of(group.entries), zone: group.zone),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  /// 切区：点区签或左右滑触发；切完重定位当前站（在新区里才滚）。
  void _setZone(int index) {
    if (!_flipEnabled || index == _zoneIndex || index < 0 || index > 1) {
      return;
    }
    setState(() {
      _zoneIndex = index;
      _scrolledToCurrent = false;
      _scrollSteps = 0;
      _lastMaxExtent = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  /// 打开弹窗自动滚到当前选中的站。宫格列表一次全建出来，选中行
  /// 首帧就在树里，直接 ensureVisible；没建出来时按视口步进往下
  /// 跳、直到它出现再 ensureVisible；到底且范围不再变就放弃。
  void _scrollToCurrent() {
    if (_scrolledToCurrent || !mounted || _scrollSteps >= 80) return;
    // 当前站不在活动区时不滚（导入区打开时当前站多半在内置区）。
    if (_flipEnabled) {
      final inZone = _zoneGroups(
        _zoneIndex,
      ).any((group) => group.entries.any((entry) => entry.id == widget.currentId));
      if (!inZone) return;
    }
    final targetContext = _currentKey.currentContext;
    if (targetContext != null) {
      _scrolledToCurrent = true;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.2,
        duration: const Duration(milliseconds: 250),
      );
      return;
    }
    _scrollSteps++;
    if (_activeScrollController.hasClients) {
      final position = _activeScrollController.position;
      final max = position.maxScrollExtent;
      if (position.pixels < max) {
        _activeScrollController.jumpTo(
          math.min(position.pixels + position.viewportDimension, max),
        );
        _lastMaxExtent = max;
      } else if (max == _lastMaxExtent) {
        return;
      } else {
        _lastMaxExtent = max;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final controller in _zoneScrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// + 号：先关弹窗（回 null，调用方不切站），再调导入回调。
  /// 回调是调用方的闭包、用调用方的 context 打开导入分流，
  /// 本弹窗已关、不存在旧分组过期问题。
  Future<void> _onAddPressed() async {
    final handler = widget.onImport;
    if (handler == null) return;
    Navigator.pop(context);
    await handler();
  }

  Future<void> _delete(SourcePickerEntry entry) async {
    final handler = widget.onDeleteSite;
    if (handler == null) return;
    final deleted = await handler(entry);
    if (!mounted || !deleted) return;
    setState(() {
      for (final group in _groups) {
        group.entries.removeWhere((item) => item.id == entry.id);
      }
      _groups.removeWhere((group) => group.entries.isEmpty);
    });
  }

  /// 长按可删：站本身可删、且调用方给了删除回调（片库区）。
  /// 与编辑模式删除图标是同一条件、同一 [_delete] 入口；调用方
  /// 的 handler 自己会弹确认框（导入站删文件、内置站隐藏）。
  bool _canDelete(SourcePickerEntry entry) =>
      entry.deletable && widget.onDeleteSite != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final searching = _query.isNotEmpty;
    // 翻页开时只取活动区的分组；不开时全取，与原来一致。
    final zoneGroups = _flipEnabled ? _zoneGroups(_zoneIndex) : _groups;
    final visible = <({String title, List<SourcePickerEntry> entries})>[];
    for (final group in zoneGroups) {
      final entries = searching
          ? group.entries
                .where((entry) => entry.name.toLowerCase().contains(_query))
                .toList()
          : group.entries;
      if (entries.isEmpty) continue;
      visible.add((title: group.title, entries: entries));
    }
    return Dialog(
      key: const ValueKey('site-picker-dialog'),
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '切换${widget.sectionName}源',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.onImport != null) ...[
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const ValueKey('site-picker-add'),
                      tooltip: '导入站点',
                      onPressed: _onAddPressed,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('site-picker-search'),
                controller: _searchController,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: '搜索站点名称',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
              if (_editMode) ...[
                const SizedBox(height: 8),
                Text(
                  '编辑模式：点删除图标可删除站点',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ] else if (widget.onDeleteSite != null) ...[
                const SizedBox(height: 8),
                Text(
                  '长按站点可删除',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (_flipEnabled) ...[
                _zoneTabs(theme, colors),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: _flipEnabled
                    ? GestureDetector(
                        // 左右滑切区：左滑进导入区，右滑回内置区。
                        onHorizontalDragEnd: (details) {
                          final velocity =
                              details.primaryVelocity ?? 0;
                          if (velocity < -80) {
                            _setZone(_zoneIndex + 1);
                          } else if (velocity > 80) {
                            _setZone(_zoneIndex - 1);
                          }
                        },
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                          child: KeyedSubtree(
                            key: ValueKey('site-picker-zone-$_zoneIndex'),
                            child: _listBody(visible, searching),
                          ),
                        ),
                      )
                    : _listBody(visible, searching),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_editMode)
                    TextButton(
                      key: const ValueKey('site-picker-done'),
                      onPressed: () => setState(() => _editMode = false),
                      child: const Text('完成'),
                    ),
                  const Spacer(),
                  OutlinedButton(
                    key: const ValueKey('site-picker-close'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 列表区本体（翻页与不翻页共用）：空态 / 宫格列表。
  /// 导入区空时给去处提示，不留白屏。
  Widget _listBody(
    List<({String title, List<SourcePickerEntry> entries})> visible,
    bool searching,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (visible.isEmpty) {
      final emptyText = _flipEnabled && _zoneIndex == 1 && !searching
          ? '导入区还没有站，点右上角 + 导入一个'
          : '没有匹配的站点';
      return Center(
        child: Text(
          emptyText,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView(
      controller: _activeScrollController,
      children: [
        for (final group in visible) ...[
          if (!searching && group.title.isNotEmpty)
            NeonSectionTitle(
              '${group.title}（${group.entries.length}）',
              padding: const EdgeInsets.only(top: 12, bottom: 4),
            ),
          _siteGrid(group),
        ],
      ],
    );
  }

  /// 区签栏：内置区 / 导入区（带站数），在翻页区外面——翻页时
  /// 区签与顶栏 + 号都不动，只有下面的列表翻。
  Widget _zoneTabs(ThemeData theme, ColorScheme colors) {
    final config = AppThemeConfig.of(context);
    Widget tab(int index, String label) {
      final selected = _zoneIndex == index;
      final count = _zoneEntryCount(index);
      return Expanded(
        child: InkWell(
          key: ValueKey(
            index == 0
                ? 'site-picker-zone-builtin'
                : 'site-picker-zone-import',
          ),
          borderRadius: BorderRadius.circular(10),
          onTap: () => _setZone(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? config.primaryColor
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              '$label（$count）',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected ? config.selectedText : config.unselectedText,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(0, '内置区'),
        const SizedBox(width: 8),
        tab(1, '导入区'),
      ],
    );
  }

  /// 图标宫格：站点呈现——圆角图标块 + 下面站名，
  /// 点块进站（与旧文字芯片点行完全一致，pop 回站 id）。
  /// 图标取不到时显示图案标，见 [SiteIcon]。
  Widget _siteGrid(({String title, List<SourcePickerEntry> entries}) group) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 480
            ? 5
            : width >= 340
            ? 4
            : 3;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 4,
            // 固定行高 74：图标 30 + 间距 4 + 两行站名，窄屏不溢出。
            mainAxisExtent: 74,
          ),
          itemCount: group.entries.length,
          itemBuilder: (context, index) => _siteGridTile(group.entries[index]),
        );
      },
    );
  }

  Widget _siteGridTile(SourcePickerEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final config = AppThemeConfig.of(context);
    final selected = entry.id == widget.currentId;
    final showDelete = _editMode && _canDelete(entry);
    return InkWell(
      key: ValueKey('site-picker-row-${entry.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: _editMode ? null : () => Navigator.pop(context, entry.id),
      onLongPress: _canDelete(entry) ? () => _delete(entry) : null,
      child: Container(
        key: selected ? _currentKey : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: selected
                        ? Border.all(color: config.primaryColor, width: 2)
                        : null,
                    boxShadow: selected ? [neonGlow(config)] : null,
                  ),
                  child: SiteIcon(
                    siteId: entry.id,
                    siteName: entry.name,
                    iconUrls: entry.iconUrls,
                    size: 30,
                    borderRadius: 14,
                  ),
                ),
                if (!_editMode && selected)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: config.primaryColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.surface, width: 2),
                      ),
                      child: Icon(
                        Icons.check,
                        size: 13,
                        color: config.selectedText,
                      ),
                    ),
                  ),
                if (showDelete)
                  Positioned(
                    top: -8,
                    right: -8,
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.error),
                      ),
                      child: IconButton(
                        key: ValueKey('site-picker-delete-${entry.id}'),
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 17),
                        color: colors.error,
                        onPressed: () => _delete(entry),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                // 长站名缩小字号换行显示（与旧芯片同一阈值）。
                fontSize: entry.name.length > 12
                    ? 9.5
                    : entry.name.length > 8
                    ? 10.5
                    : 12,
                color: selected ? config.primaryColor : config.unselectedText,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
