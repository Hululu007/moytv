import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'core_bridge.dart';
import 'neon_glass_kit.dart';
import 'site_cube.dart';
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
  const SourcePickerGroup({required this.title, required this.entries});

  final String title;
  final List<SourcePickerEntry> entries;
}

class _EditableGroup {
  _EditableGroup(this.title, this.entries);

  final String title;
  final List<SourcePickerEntry> entries;
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

  /// 取各站首页海报用的仓库：非空且当前主题列表样式为方块时，
  /// 弹窗改渲染 3D 方块列；为空时永远是普通列表（直播/阅读区
  /// 不传，方块只在片库区出现）。
  AppRepository? repository,
}) => showDialog<String>(
  context: context,
  builder: (context) => SitePickerDialog(
    sectionName: sectionName,
    currentId: currentId,
    groups: groups,
    initialEditMode: initialEditMode,
    onDeleteSite: onDeleteSite,
    onImport: onImport,
    repository: repository,
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
    this.repository,
  });

  final String sectionName;
  final String currentId;
  final List<SourcePickerGroup> groups;
  final bool initialEditMode;
  final Future<bool> Function(SourcePickerEntry entry)? onDeleteSite;
  final Future<void> Function()? onImport;
  final AppRepository? repository;

  @override
  State<SitePickerDialog> createState() => _SitePickerDialogState();
}

class _SitePickerDialogState extends State<SitePickerDialog> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _currentKey = GlobalKey();
  String _query = '';
  bool _scrolledToCurrent = false;
  int _scrollSteps = 0;
  double _lastMaxExtent = -1;
  late bool _editMode;
  late List<_EditableGroup> _groups;

  @override
  void initState() {
    super.initState();
    _editMode = widget.initialEditMode && widget.onDeleteSite != null;
    _groups = [
      for (final group in widget.groups)
        _EditableGroup(group.title, List.of(group.entries)),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  /// 打开弹窗自动滚到当前选中的站。宫格列表一次全建出来，选中行
  /// 首帧就在树里，直接 ensureVisible；方块列是懒加载（每行进树
  /// 才请求封面，不能改全量），选中行没建出来时按视口步进往下
  /// 跳、直到它出现再 ensureVisible；到底且范围不再变就放弃。
  void _scrollToCurrent() {
    if (_scrolledToCurrent || !mounted || _scrollSteps >= 80) return;
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
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      final max = position.maxScrollExtent;
      if (position.pixels < max) {
        _scrollController.jumpTo(
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
    _scrollController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final searching = _query.isNotEmpty;
    final visible = <({String title, List<SourcePickerEntry> entries})>[];
    for (final group in _groups) {
      final entries = searching
          ? group.entries
                .where((entry) => entry.name.toLowerCase().contains(_query))
                .toList()
          : group.entries;
      if (entries.isEmpty) continue;
      visible.add((title: group.title, entries: entries));
    }
    // 方块列只在三个条件同时满足时出现：调用方传了仓库（片库区）、
    // 当前主题列表样式为方块、且不在编辑模式（编辑模式要留删除按钮，
    // 仍用普通列表）。其它情况一律走原有普通列表，一字不动。
    final cubeMode =
        widget.repository != null &&
        !_editMode &&
        siteListStyleForTheme(AppThemeConfig.of(context).mode) ==
            SiteListStyle.cube;
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
              ],
              const SizedBox(height: 8),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的站点',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      )
                    : cubeMode
                    ? _cubeList(visible, searching)
                    : ListView(
                        controller: _scrollController,
                        children: [
                          for (final group in visible) ...[
                            if (!searching && group.title.isNotEmpty)
                              NeonSectionTitle(
                                '${group.title}（${group.entries.length}）',
                                padding: const EdgeInsets.only(
                                  top: 12,
                                  bottom: 4,
                                ),
                              ),
                            _siteGrid(group),
                          ],
                        ],
                      ),
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

  /// 图标宫格：普通列表样式下的站点呈现——圆角图标块 + 下面站名，
  /// 点块进站（与旧文字芯片点行完全一致，pop 回站 id）。方块列
  /// （霓虹主题 + 传仓库 + 非编辑模式）走 [_cubeList]，不受影响。
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
    final showDelete =
        _editMode && entry.deletable && widget.onDeleteSite != null;
    return InkWell(
      key: ValueKey('site-picker-row-${entry.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: _editMode ? null : () => Navigator.pop(context, entry.id),
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

  /// 方块列：每站一行（方块 + 站名），点方块与普通列表点行完全一致
  /// （pop 回站 id，调用方切站进频道）。惰性 ListView：只有滚到眼前
  /// 的行才取首页海报，避免开弹窗就并发打全部站。
  Widget _cubeList(
    List<({String title, List<SourcePickerEntry> entries})> visible,
    bool searching,
  ) {
    final rows = <_CubeRow>[];
    for (final group in visible) {
      if (!searching && group.title.isNotEmpty) {
        rows.add(_CubeRow.header('${group.title}（${group.entries.length}）'));
      }
      for (final entry in group.entries) {
        rows.add(_CubeRow.entry(entry));
      }
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final header = row.header;
        if (header != null) {
          return NeonSectionTitle(
            header,
            padding: const EdgeInsets.only(top: 12, bottom: 4),
          );
        }
        final entry = row.entry!;
        final selected = entry.id == widget.currentId;
        return _SiteCubeRow(
          key: ValueKey('site-picker-row-${entry.id}'),
          entry: entry,
          selected: selected,
          currentKey: selected ? _currentKey : null,
          repository: widget.repository!,
          onTap: () => Navigator.pop(context, entry.id),
        );
      },
    );
  }
}

/// 方块列里的一行：组标题，或一个站点。
class _CubeRow {
  const _CubeRow.header(this.header) : entry = null;

  const _CubeRow.entry(this.entry) : header = null;

  final String? header;
  final SourcePickerEntry? entry;
}

/// 方块列里的一站：方块（六个面取该站首页前 6 张海报）+ 站名行。
/// 海报用调用方已有的仓库取：catalog(siteId, page: 1) 取首页条目，
/// 再逐条调 repository.cover 解析成本地封面文件；任一环节失败或
/// 为空都显示占位面，不编假图、不另写裸请求。
class _SiteCubeRow extends StatefulWidget {
  const _SiteCubeRow({
    super.key,
    required this.entry,
    required this.selected,
    this.currentKey,
    required this.repository,
    required this.onTap,
  });

  final SourcePickerEntry entry;
  final bool selected;

  /// 当前站的定位 key（滚到当前站用），只在选中行上挂。
  final Key? currentKey;
  final AppRepository repository;
  final VoidCallback onTap;

  @override
  State<_SiteCubeRow> createState() => _SiteCubeRowState();
}

class _SiteCubeRowState extends State<_SiteCubeRow> {
  late final Future<List<String>> _covers;

  @override
  void initState() {
    super.initState();
    _covers = _loadCovers();
  }

  Future<List<String>> _loadCovers() async {
    try {
      final page = await widget.repository.catalog(widget.entry.id, page: 1);
      final covers = <String>[];
      for (final drama in page.items.take(6)) {
        try {
          final resolved = await widget.repository.cover(drama);
          if (resolved.isNotEmpty) {
            covers.add(resolved);
            continue;
          }
        } catch (_) {
          // 单张解析失败就回落到条目自带的封面地址，继续下一张。
        }
        if (drama.cover.isNotEmpty) covers.add(drama.cover);
      }
      return covers;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final theme = Theme.of(context);
    return Container(
      key: widget.currentKey,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          FutureBuilder<List<String>>(
            future: _covers,
            builder: (context, snapshot) => SiteCube(
              siteName: widget.entry.name,
              covers: snapshot.data ?? const [],
              size: 132,
              onTap: widget.onTap,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  widget.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: widget.selected
                        ? config.primaryColor
                        : config.unselectedText,
                    fontWeight: widget.selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (widget.selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check, size: 18, color: config.primaryColor),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
