import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'core_bridge.dart';
import 'neon_glass_kit.dart';
import 'site_cube.dart';

class SourcePickerEntry {
  const SourcePickerEntry({
    required this.id,
    required this.name,
    this.deletable = true,
  });

  final String id;
  final String name;
  final bool deletable;
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
    this.repository,
  });

  final String sectionName;
  final String currentId;
  final List<SourcePickerGroup> groups;
  final bool initialEditMode;
  final Future<bool> Function(SourcePickerEntry entry)? onDeleteSite;
  final AppRepository? repository;

  @override
  State<SitePickerDialog> createState() => _SitePickerDialogState();
}

class _SitePickerDialogState extends State<SitePickerDialog> {
  final _searchController = TextEditingController();
  final _currentKey = GlobalKey();
  String _query = '';
  bool _scrolledToCurrent = false;
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

  void _scrollToCurrent() {
    if (_scrolledToCurrent) return;
    final context = _currentKey.currentContext;
    if (context == null || !mounted) return;
    _scrolledToCurrent = true;
    Scrollable.ensureVisible(
      context,
      alignment: 0.2,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
              Text(
                '切换${widget.sectionName}源',
                style: theme.textTheme.titleMedium,
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
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 128,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                    childAspectRatio: 2.4,
                                  ),
                              itemCount: group.entries.length,
                              itemBuilder: (context, index) {
                                final entry = group.entries[index];
                                final selected = entry.id == widget.currentId;
                                final config = AppThemeConfig.of(context);
                                return InkWell(
                                  key: ValueKey('site-picker-row-${entry.id}'),
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _editMode
                                      ? null
                                      : () => Navigator.pop(context, entry.id),
                                  child: Container(
                                    key: selected ? _currentKey : null,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: selected
                                          ? neonSelectedGradient(config)
                                          : null,
                                      color: selected
                                          ? null
                                          : config.unselectedBg,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: selected
                                            ? Colors.transparent
                                            : config.dividerColor,
                                      ),
                                      boxShadow: selected
                                          ? [neonGlow(config)]
                                          : null,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            entry.name,
                                            maxLines: 2,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  // 长站名缩小字号换行显示，
                                                  // 不截断、不省略号。
                                                  fontSize:
                                                      entry.name.length > 12
                                                      ? 9.5
                                                      : entry.name.length > 8
                                                      ? 10.5
                                                      : 12,
                                                  color: selected
                                                      ? config.selectedText
                                                      : config.unselectedText,
                                                  fontWeight: selected
                                                      ? FontWeight.w600
                                                      : null,
                                                ),
                                          ),
                                        ),
                                        if (!_editMode && selected)
                                          Icon(
                                            Icons.check,
                                            size: 18,
                                            color: config.selectedText,
                                          )
                                        else if (_editMode &&
                                            entry.deletable &&
                                            widget.onDeleteSite != null)
                                          IconButton(
                                            key: ValueKey(
                                              'site-picker-delete-${entry.id}',
                                            ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              size: 20,
                                            ),
                                            color: colors.error,
                                            onPressed: () => _delete(entry),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
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
        rows.add(
          _CubeRow.header('${group.title}（${group.entries.length}）'),
        );
      }
      for (final entry in group.entries) {
        rows.add(_CubeRow.entry(entry));
      }
    }
    return ListView.builder(
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
      final page = await widget.repository.catalog(
        widget.entry.id,
        page: 1,
      );
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
