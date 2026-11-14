import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'neon_glass_kit.dart';

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
}) => showDialog<String>(
  context: context,
  builder: (context) => SitePickerDialog(
    sectionName: sectionName,
    currentId: currentId,
    groups: groups,
    initialEditMode: initialEditMode,
    onDeleteSite: onDeleteSite,
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
  });

  final String sectionName;
  final String currentId;
  final List<SourcePickerGroup> groups;
  final bool initialEditMode;
  final Future<bool> Function(SourcePickerEntry entry)? onDeleteSite;

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
}
